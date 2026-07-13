#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

root = File.expand_path("..", __dir__)
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/swing_point_detector"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/move_labeler"
require_relative "../lib/signature_analyzer"
require_relative "../lib/dynamic_risk_planner"
require_relative "../lib/walk_forward_validator"
require_relative "../lib/backtest_simulator"
require_relative "../lib/candle_resampler"

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
INTERVAL = "15m"
DAYS_BACK = 90
WALK_FORWARD_FOLDS = 6
EMBARGO_BARS = 5 # Reduced embargo for 1h candles
CACHE_DIR = File.join(root, "data", "cache")

STARTING_BALANCE_INR = 100_000.0
EXCHANGE_RATE = 83.5 # INR/USDT

# 1. Load data and resample to 1h for all symbols
candles_by_symbol = {}
funding_series_by_symbol = {}
regimes_by_symbol = {}
aligned_4h_regimes_by_symbol = {}
swings_by_symbol = {}
feature_extractor_by_symbol = {}

puts "======================================================================"
puts "1H TIMEFRAME PORTFOLIO BACKTEST SIMULATOR"
puts "======================================================================"

SYMBOLS.each do |symbol|
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_#{DAYS_BACK}d.json")))
  
  candles_15m = BinanceDataLoader.klines_to_candles(raw_klines)
  # Resample 15m to 1h (factor = 4)
  candles = CandleResampler.resample_candles(candles_15m, 4)
  
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  profile = SymbolProfile.for(symbol)
  
  regimes = RegimeClassifier.new(profile).classify(candles)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  extractor = ContextFeatureExtractor.new(profile)
  
  # Warm up caches
  closes = candles.map { |c| c[:close] }
  extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
  extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)
  
  # Align 4h regimes for MTF gating (1h * 4 = 4h)
  htf_factor = 4
  htf_candles = CandleResampler.resample_candles(candles, htf_factor)
  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_4h_regimes = CandleResampler.align_higher_regimes(
    lower_candles: candles,
    higher_candles: htf_candles,
    higher_regimes: htf_regimes
  )
  
  candles_by_symbol[symbol] = candles
  funding_series_by_symbol[symbol] = funding_series
  regimes_by_symbol[symbol] = regimes
  aligned_4h_regimes_by_symbol[symbol] = aligned_4h_regimes
  swings_by_symbol[symbol] = swings
  feature_extractor_by_symbol[symbol] = extractor
  
  puts "#{symbol}: #{candles.size} candles, #{swings.size} swings"
end

# Build folds
total_bars = candles_by_symbol[SYMBOLS.first].size
folds = WalkForwardValidator.build_folds(total_bars: total_bars, n_folds: WALK_FORWARD_FOLDS, embargo_bars: EMBARGO_BARS)

# Helper to calibrate optimal parameters for a symbol on training fold data
def calibrate_symbol(symbol:, candles:, swings:, regimes:, funding_series:, extractor:, train_range:)
  profile = SymbolProfile.for(symbol)
  best_params = { stop_atr_buffer: 0.5, entry_delay_bars: 1, forward_horizon_bars: 20 }
  best_expectancy = -Float::INFINITY
  
  stops = [0.5, 1.0]
  delays = [1, 3]
  horizons = [10, 20]
  
  stops.each do |stop|
    delays.each do |delay|
      horizons.each do |horz|
        labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: stop)
        
        # Label signal events in the train range
        events = labeler.label_signal_events(
          candles: candles[0..train_range.end],
          swings: swings.select { |s| train_range.cover?(s.index) },
          regimes: regimes[0..train_range.end],
          funding_series: funding_series[0..train_range.end],
          feature_extractor: extractor,
          entry_delay_bars: delay,
          forward_horizon_bars: horz
        )
        
        baselines = labeler.label_baseline_samples(
          candles: candles[0..train_range.end],
          regimes: regimes[0..train_range.end],
          funding_series: funding_series[0..train_range.end],
          feature_extractor: extractor,
          forward_horizon_bars: horz,
          stride: 5
        )
        
        buckets = SignatureAnalyzer.analyze(swing_events: events, baseline_samples: baselines)
        
        # Find if there are any tradeable buckets and sum their edge
        tradeable_count = 0
        total_exp = 0.0
        
        buckets.each do |b|
          plan = DynamicRiskPlanner.plan(bucket_stats: b)
          if plan.tradeable
            tradeable_count += 1
            total_exp += b.edge_over_baseline || 0.0
          end
        end
        
        if tradeable_count.positive? && total_exp > best_expectancy
          best_expectancy = total_exp
          best_params = { stop_atr_buffer: stop, entry_delay_bars: delay, forward_horizon_bars: horz }
        end
      end
    end
  end
  
  [best_params, best_expectancy]
end

# We will run three scenarios:
# 1. Baseline Prior
# 2. Walk-Forward Calibrated (OOS)
# 3. Calibrated + 4h MTF Trend Alignment (OOS)
scenarios = {
  baseline: {
    name: "Baseline Prior (Fixed)",
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  },
  calibrated: {
    name: "Walk-Forward Calibrated",
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  },
  calibrated_mtf: {
    name: "Calibrated + 4h MTF Align",
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  }
}

puts "\nStarting Chronological Cash Backtest..."

folds.each_with_index do |fold, fold_idx|
  puts "\n--- FOLD #{fold_idx + 1} ---"
  
  # 1. Calibration phase
  calibrated_params = {}
  tradeable_buckets_by_symbol = {}
  
  SYMBOLS.each do |symbol|
    candles = candles_by_symbol[symbol]
    swings = swings_by_symbol[symbol]
    regimes = regimes_by_symbol[symbol]
    funding_series = funding_series_by_symbol[symbol]
    extractor = feature_extractor_by_symbol[symbol]
    profile = SymbolProfile.for(symbol)
    
    params, edge = calibrate_symbol(
      symbol: symbol, candles: candles, swings: swings, regimes: regimes,
      funding_series: funding_series, extractor: extractor, train_range: fold.train_range
    )
    
    calibrated_params[symbol] = params
    
    labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: params[:stop_atr_buffer])
    train_events = labeler.label_signal_events(
      candles: candles[0..fold.train_range.end],
      swings: swings.select { |s| fold.train_range.cover?(s.index) },
      regimes: regimes[0..fold.train_range.end],
      funding_series: funding_series[0..fold.train_range.end],
      feature_extractor: extractor,
      entry_delay_bars: params[:entry_delay_bars],
      forward_horizon_bars: params[:forward_horizon_bars]
    )
    
    train_baselines = labeler.label_baseline_samples(
      candles: candles[0..fold.train_range.end],
      regimes: regimes[0..fold.train_range.end],
      funding_series: funding_series[0..fold.train_range.end],
      feature_extractor: extractor,
      forward_horizon_bars: params[:forward_horizon_bars],
      stride: 5
    )
    
    buckets = SignatureAnalyzer.analyze(swing_events: train_events, baseline_samples: train_baselines)
    
    tradeable_buckets = {}
    buckets.each do |bucket|
      plan = DynamicRiskPlanner.plan(bucket_stats: bucket)
      next unless plan.tradeable
      
      bucket_events = train_events.select { |e| e.context[:regime_state] == bucket.bucket_key }
      dominant_direction = bucket_events.group_by(&:direction).max_by { |_, v| v.size }&.first
      next if dominant_direction.nil?
      
      tradeable_buckets[bucket.bucket_key] = { plan: plan, direction: dominant_direction }
    end
    
    tradeable_buckets_by_symbol[symbol] = tradeable_buckets
    puts "  [#{symbol}] Calibrated Params: stop=#{params[:stop_atr_buffer]} delay=#{params[:entry_delay_bars]} horizon=#{params[:forward_horizon_bars]} (edge sum = #{edge.round(3)})"
  end
  
  # Baseline calibration (Fixed params: stop=0.5, delay=1, horizon=20)
  baseline_tradeable_buckets_by_symbol = {}
  SYMBOLS.each do |symbol|
    candles = candles_by_symbol[symbol]
    swings = swings_by_symbol[symbol]
    regimes = regimes_by_symbol[symbol]
    funding_series = funding_series_by_symbol[symbol]
    extractor = feature_extractor_by_symbol[symbol]
    profile = SymbolProfile.for(symbol)
    
    labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: 0.5)
    train_events = labeler.label_signal_events(
      candles: candles[0..fold.train_range.end],
      swings: swings.select { |s| fold.train_range.cover?(s.index) },
      regimes: regimes[0..fold.train_range.end],
      funding_series: funding_series[0..fold.train_range.end],
      feature_extractor: extractor,
      entry_delay_bars: 1,
      forward_horizon_bars: 20
    )
    
    train_baselines = labeler.label_baseline_samples(
      candles: candles[0..fold.train_range.end],
      regimes: regimes[0..fold.train_range.end],
      funding_series: funding_series[0..fold.train_range.end],
      feature_extractor: extractor,
      forward_horizon_bars: 20,
      stride: 5
    )
    
    buckets = SignatureAnalyzer.analyze(swing_events: train_events, baseline_samples: train_baselines)
    
    tradeable_buckets = {}
    buckets.each do |bucket|
      plan = DynamicRiskPlanner.plan(bucket_stats: bucket)
      next unless plan.tradeable
      
      bucket_events = train_events.select { |e| e.context[:regime_state] == bucket.bucket_key }
      dominant_direction = bucket_events.group_by(&:direction).max_by { |_, v| v.size }&.first
      next if dominant_direction.nil?
      
      tradeable_buckets[bucket.bucket_key] = { plan: plan, direction: dominant_direction }
    end
    baseline_tradeable_buckets_by_symbol[symbol] = tradeable_buckets
  end

  test_start_ts = candles_by_symbol[SYMBOLS.first][fold.test_range.first][:ts]
  test_end_ts = candles_by_symbol[SYMBOLS.first][fold.test_range.max][:ts]

  # 2. Execution phase on test fold OOS data
  
  # SCENARIO 1: Baseline
  simulator_baseline = BacktestSimulator.new(
    starting_balance_inr: scenarios[:baseline][:compounded_balance_usdt] * EXCHANGE_RATE,
    exchange_rate_inr_usdt: EXCHANGE_RATE
  )
  res_baseline = simulator_baseline.run(
    candles_by_symbol: candles_by_symbol,
    funding_series_by_symbol: funding_series_by_symbol,
    swings_by_symbol: swings_by_symbol,
    regimes_by_symbol: regimes_by_symbol,
    feature_extractor_by_symbol: feature_extractor_by_symbol,
    tradeable_buckets_by_symbol: baseline_tradeable_buckets_by_symbol,
    entry_delay_bars: 1,
    forward_horizon_bars: 20
  )
  fold_trades_baseline = res_baseline[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
  scenarios[:baseline][:trades] += fold_trades_baseline
  scenarios[:baseline][:compounded_balance_usdt] += fold_trades_baseline.sum(&:net_pnl_usdt)
  
  # SCENARIO 2: Calibrated
  simulator_calibrated = BacktestSimulator.new(
    starting_balance_inr: scenarios[:calibrated][:compounded_balance_usdt] * EXCHANGE_RATE,
    exchange_rate_inr_usdt: EXCHANGE_RATE
  )
  res_calibrated = simulator_calibrated.run(
    candles_by_symbol: candles_by_symbol,
    funding_series_by_symbol: funding_series_by_symbol,
    swings_by_symbol: swings_by_symbol,
    regimes_by_symbol: regimes_by_symbol,
    feature_extractor_by_symbol: feature_extractor_by_symbol,
    tradeable_buckets_by_symbol: tradeable_buckets_by_symbol,
    params_by_symbol: calibrated_params
  )
  fold_trades_calibrated = res_calibrated[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
  scenarios[:calibrated][:trades] += fold_trades_calibrated
  scenarios[:calibrated][:compounded_balance_usdt] += fold_trades_calibrated.sum(&:net_pnl_usdt)
  
  # SCENARIO 3: Calibrated + MTF 4h (1h candles gated by 4h macro trend)
  simulator_mtf = BacktestSimulator.new(
    starting_balance_inr: scenarios[:calibrated_mtf][:compounded_balance_usdt] * EXCHANGE_RATE,
    exchange_rate_inr_usdt: EXCHANGE_RATE
  )
  res_mtf = simulator_mtf.run(
    candles_by_symbol: candles_by_symbol,
    funding_series_by_symbol: funding_series_by_symbol,
    swings_by_symbol: swings_by_symbol,
    regimes_by_symbol: regimes_by_symbol,
    feature_extractor_by_symbol: feature_extractor_by_symbol,
    tradeable_buckets_by_symbol: tradeable_buckets_by_symbol,
    params_by_symbol: calibrated_params,
    htf_regimes_by_symbol: aligned_4h_regimes_by_symbol
  )
  fold_trades_mtf = res_mtf[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
  scenarios[:calibrated_mtf][:trades] += fold_trades_mtf
  scenarios[:calibrated_mtf][:compounded_balance_usdt] += fold_trades_mtf.sum(&:net_pnl_usdt)
  
  # Record equity curve points
  scenarios.each do |key, sc|
    sc[:equity_curve] << {
      fold: fold_idx + 1,
      timestamp: test_end_ts,
      balance_inr: (sc[:compounded_balance_usdt] * EXCHANGE_RATE).round(2),
      trades_in_fold: case key
                      when :baseline then fold_trades_baseline.size
                      when :calibrated then fold_trades_calibrated.size
                      when :calibrated_mtf then fold_trades_mtf.size
                      end
    }
  end
  
  puts "  Baseline:     trades=#{fold_trades_baseline.size}  net_pnl=#{(fold_trades_baseline.sum(&:net_pnl_usdt) * EXCHANGE_RATE).round(2)} INR  (Ending: #{(scenarios[:baseline][:compounded_balance_usdt] * EXCHANGE_RATE).round(2)} INR)"
  puts "  Calibrated:   trades=#{fold_trades_calibrated.size}  net_pnl=#{(fold_trades_calibrated.sum(&:net_pnl_usdt) * EXCHANGE_RATE).round(2)} INR  (Ending: #{(scenarios[:calibrated][:compounded_balance_usdt] * EXCHANGE_RATE).round(2)} INR)"
  puts "  Calib + MTF:  trades=#{fold_trades_mtf.size}  net_pnl=#{(fold_trades_mtf.sum(&:net_pnl_usdt) * EXCHANGE_RATE).round(2)} INR  (Ending: #{(scenarios[:calibrated_mtf][:compounded_balance_usdt] * EXCHANGE_RATE).round(2)} INR)"
end

# Calculate aggregate results & prepare export payload
export_payload = {}

puts "\n" + "=" * 70
puts "1H TIMEFRAME COMPARATIVE REPORT"
puts "=" * 70

scenarios.each do |key, sc|
  total_trades = sc[:trades].size
  winning_trades = sc[:trades].count { |t| t.net_pnl_usdt.positive? }
  win_rate = total_trades.positive? ? (winning_trades.to_f / total_trades) : 0.0
  
  final_balance_usdt = sc[:compounded_balance_usdt]
  final_balance_inr = final_balance_usdt * EXCHANGE_RATE
  net_profit_inr = final_balance_inr - STARTING_BALANCE_INR
  net_profit_pct = (net_profit_inr / STARTING_BALANCE_INR) * 100.0
  
  # Drawdown calculation
  running_equity = STARTING_BALANCE_INR / EXCHANGE_RATE
  peak_equity = running_equity
  max_dd = 0.0
  sc[:trades].sort_by(&:entry_ts).each do |t|
    running_equity += t.net_pnl_usdt
    peak_equity = [peak_equity, running_equity].max
    dd = (peak_equity - running_equity) / peak_equity
    max_dd = [max_dd, dd].max
  end
  
  # Annualized Sharpe ratio proxy
  pnl_values = sc[:trades].map(&:net_pnl_usdt)
  sharpe = 0.0
  if pnl_values.size > 5
    mean = pnl_values.sum / pnl_values.size.to_f
    variance = pnl_values.sum { |v| (v - mean)**2 } / pnl_values.size.to_f
    std = Math.sqrt(variance)
    sharpe = std.zero? ? 0.0 : (mean / std) * Math.sqrt(252)
  end
  
  puts sc[:name]
  puts "  Net Profit: #{net_profit_inr.round(2)} INR (#{net_profit_pct.round(2)}%)"
  puts "  Drawdown:   #{(max_dd * 100.0).round(2)}% | Sharpe Ratio: #{sharpe.round(2)}"
  puts "  Win Rate:   #{(win_rate * 100.0).round(2)}% (#{winning_trades} wins, #{total_trades - winning_trades} losses)"
  
  # Format trades for JSON export
  trade_list = sc[:trades].sort_by(&:entry_ts).map do |t|
    {
      symbol: t.symbol,
      direction: t.direction,
      entry_time: Time.at(t.entry_ts).strftime("%m-%d %H:%M"),
      exit_time: Time.at(t.exit_ts).strftime("%m-%d %H:%M"),
      entry_price: t.entry_price.round(4),
      exit_price: t.exit_price.round(4),
      quantity: t.quantity,
      notional: t.notional,
      leverage: t.leverage,
      net_pnl_inr: t.net_pnl_inr.round(2),
      ending_equity_inr: (t.ending_equity_usdt * EXCHANGE_RATE).round(2),
      regime: t.bucket_key
    }
  end
  
  export_payload[key] = {
    name: sc[:name],
    metrics: {
      starting_balance_inr: STARTING_BALANCE_INR.round(2),
      final_balance_inr: final_balance_inr.round(2),
      net_profit_inr: net_profit_inr.round(2),
      net_profit_pct: net_profit_pct.round(2),
      max_drawdown_pct: (max_dd * 100.0).round(2),
      sharpe_ratio: sharpe.round(2),
      total_trades: total_trades,
      win_rate_pct: (win_rate * 100.0).round(2),
      wins: winning_trades,
      losses: total_trades - winning_trades
    },
    equity_curve: sc[:equity_curve],
    trades: trade_list
  }
end

# Compile HTML dashboard with inline data
template_path = File.join(root, "data", "dashboard_template.html")
if File.exist?(template_path)
  template_content = File.read(template_path)
  compiled_content = template_content.gsub(
    "// INSERT_BACKTEST_DATA_HERE",
    "window.backtestData = #{JSON.dump(export_payload)};"
  )
  # Modify title to reflect 1H timeframe
  compiled_content = compiled_content.gsub(
    "<h1>Crypto perp futures backtest analytics</h1>",
    "<h1>Crypto perp futures backtest analytics (1H Timeframe)</h1>"
  )
  compiled_content = compiled_content.gsub(
    "<h3>Calibrated + 1h MTF Align</h3>",
    "<h3>Calibrated + 4h MTF Align</h3>"
  )
  
  dashboard_path = File.join(root, "data", "backtest_dashboard_1h.html")
  File.write(dashboard_path, compiled_content)
  puts "HTML Dashboard compiled to #{dashboard_path} with embedded 1H backtest data."
else
  puts "WARNING: dashboard_template.html not found at #{template_path}"
end

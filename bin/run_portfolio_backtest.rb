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
EMBARGO_BARS_2H = 3
CACHE_DIR = File.join(root, "data", "cache")

STARTING_BALANCE_INR = 100_000.0
EXCHANGE_RATE = 83.5 # INR/USDT

# 1. Load raw 15m data and resample to 2H for active scenarios
candles_15m_by_symbol = {}
funding_15m_by_symbol = {}
regimes_15m_by_symbol = {}
swings_15m_by_symbol = {}
extractor_15m_by_symbol = {}

candles_2h_by_symbol = {}
funding_2h_by_symbol = {}
regimes_2h_by_symbol = {}
aligned_4h_regimes_by_symbol = {}
swings_2h_by_symbol = {}
extractor_2h_by_symbol = {}

puts "======================================================================"
puts "ULTIMATE COMPOSITE ALPHA BACKTEST SIMULATOR (Starting: #{STARTING_BALANCE_INR} INR)"
puts "======================================================================"

SYMBOLS.each do |symbol|
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_#{DAYS_BACK}d.json")))
  
  # 15m Series (For Scenario 1)
  candles_15m = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_15m = BinanceDataLoader.align_funding_series(candles_15m, raw_funding)
  profile = SymbolProfile.for(symbol)
  regimes_15m = RegimeClassifier.new(profile).classify(candles_15m)
  swings_15m = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles_15m)
  extractor_15m = ContextFeatureExtractor.new(profile)
  
  closes_15m = candles_15m.map { |c| c[:close] }
  extractor_15m.ema_cache_fast = Indicators.ema(closes_15m, profile.ema_fast)
  extractor_15m.ema_cache_slow = Indicators.ema(closes_15m, profile.ema_slow)
  
  candles_15m_by_symbol[symbol] = candles_15m
  funding_15m_by_symbol[symbol] = funding_15m
  regimes_15m_by_symbol[symbol] = regimes_15m
  swings_15m_by_symbol[symbol] = swings_15m
  extractor_15m_by_symbol[symbol] = extractor_15m
  
  # 2H Series (For Scenario 2 & 3, resampling factor = 8)
  candles_2h = CandleResampler.resample_candles(candles_15m, 8)
  funding_2h = BinanceDataLoader.align_funding_series(candles_2h, raw_funding)
  regimes_2h = RegimeClassifier.new(profile).classify(candles_2h)
  swings_2h = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles_2h)
  extractor_2h = ContextFeatureExtractor.new(profile)
  
  closes_2h = candles_2h.map { |c| c[:close] }
  extractor_2h.ema_cache_fast = Indicators.ema(closes_2h, profile.ema_fast)
  extractor_2h.ema_cache_slow = Indicators.ema(closes_2h, profile.ema_slow)
  
  # Precompute and cache RSI for 2H candles
  extractor_2h.rsi_cache = Indicators.rsi(candles_2h, 14)
  
  # Align 4h regimes for MTF gating (2h * 2 = 4h)
  htf_candles = CandleResampler.resample_candles(candles_2h, 2)
  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_4h_regimes = CandleResampler.align_higher_regimes(
    lower_candles: candles_2h,
    higher_candles: htf_candles,
    higher_regimes: htf_regimes
  )
  
  candles_2h_by_symbol[symbol] = candles_2h
  funding_2h_by_symbol[symbol] = funding_2h
  regimes_2h_by_symbol[symbol] = regimes_2h
  aligned_4h_regimes_by_symbol[symbol] = aligned_4h_regimes
  swings_2h_by_symbol[symbol] = swings_2h
  extractor_2h_by_symbol[symbol] = extractor_2h
  
  puts "#{symbol}: 15m and 2H candles loaded successfully."
end

# Build folds based on 2H candle count
total_bars_2h = candles_2h_by_symbol[SYMBOLS.first].size
folds_2h = WalkForwardValidator.build_folds(total_bars: total_bars_2h, n_folds: WALK_FORWARD_FOLDS, embargo_bars: EMBARGO_BARS_2H)

# Gated Simulator subclass to allow post-entry gating hooks
class GatedSimulator < BacktestSimulator
  def run_with_filter(candles_by_symbol:, funding_series_by_symbol:, swings_by_symbol:, regimes_by_symbol:, feature_extractor_by_symbol:, tradeable_buckets_by_symbol:, params_by_symbol:, aligned_htf_by_symbol: nil, filter_proc: nil, bar_interval_mins: 15)
    
    all_events = []
    candles_by_symbol.each do |symbol, candles|
      profile = SymbolProfile.for(symbol)
      swings = swings_by_symbol[symbol]
      regimes = regimes_by_symbol[symbol]
      funding_series = funding_series_by_symbol[symbol]
      extractor = feature_extractor_by_symbol[symbol]
      sym_params = params_by_symbol[symbol]
      
      labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: sym_params[:stop_atr_buffer])
      events = labeler.label_signal_events(
        candles: candles, swings: swings, regimes: regimes,
        funding_series: funding_series, feature_extractor: extractor,
        entry_delay_bars: sym_params[:entry_delay_bars], forward_horizon_bars: sym_params[:forward_horizon_bars]
      )
      
      events.each do |event|
        all_events << { symbol: symbol, event: event }
      end
    end
    
    all_events.sort_by! { |item| item[:event].entry_ts }
    
    equity_usdt = @starting_balance_usdt
    peak_equity_usdt = equity_usdt
    max_drawdown_pct = 0.0
    
    open_trades = []
    trade_logs = []
    
    all_events.each do |item|
      symbol = item[:symbol]
      event = item[:event]
      profile = SymbolProfile.for(symbol)
      sizer = PositionSizer.new(profile)
      
      # Settle open trades
      open_trades.reject! do |open_trade|
        if open_trade[:exit_ts] <= event.entry_ts
          pnl_info = calculate_net_pnl(
            event: open_trade[:event],
            quantity: open_trade[:quantity],
            funding_series: funding_series_by_symbol[open_trade[:symbol]],
            bar_interval_minutes: bar_interval_mins
          )
          
          equity_usdt += pnl_info[:net_pnl_usdt]
          peak_equity_usdt = [peak_equity_usdt, equity_usdt].max
          dd = (peak_equity_usdt - equity_usdt) / peak_equity_usdt
          max_drawdown_pct = [max_drawdown_pct, dd].max
          
          trade_logs << BacktestSimulator::TradeLog.new(
            symbol: open_trade[:symbol],
            direction: open_trade[:event].direction,
            entry_ts: open_trade[:event].entry_ts,
            exit_ts: open_trade[:exit_ts],
            entry_price: open_trade[:event].entry_price,
            stop_price: open_trade[:event].stop_price,
            exit_price: open_trade[:event].exit_price,
            quantity: open_trade[:quantity],
            notional: open_trade[:notional],
            leverage: open_trade[:leverage],
            gross_pnl_usdt: pnl_info[:gross_pnl_usdt],
            fees_usdt: pnl_info[:fees_usdt],
            slippage_usdt: pnl_info[:slippage_usdt],
            funding_usdt: pnl_info[:funding_usdt],
            net_pnl_usdt: pnl_info[:net_pnl_usdt],
            net_pnl_inr: pnl_info[:net_pnl_usdt] * @exchange_rate_inr_usdt,
            ending_equity_usdt: equity_usdt,
            bucket_key: open_trade[:bucket_key]
          )
          true
        else
          false
        end
      end
      
      bucket_key = event.context[:regime_state]
      tradeable_info = tradeable_buckets_by_symbol[symbol][bucket_key]
      next if tradeable_info.nil?
      next if event.direction != tradeable_info[:direction]
      
      # Filter hook
      aligned_htf = aligned_htf_by_symbol ? aligned_htf_by_symbol[symbol] : nil
      next if filter_proc && !filter_proc.call(event, aligned_htf)
      
      risk_pct = tradeable_info[:plan].risk_pct
      current_open_notional = open_trades.sum { |t| t[:notional] }
      max_allowed_new_notional = (equity_usdt * profile.max_leverage) - current_open_notional
      next if max_allowed_new_notional <= 0
      
      begin
        sizing = sizer.size(
          account_equity: equity_usdt,
          entry_price: event.entry_price,
          stop_price: event.stop_price,
          risk_pct: risk_pct,
          direction: event.direction
        )
        
        quantity = sizing.quantity
        notional = sizing.notional
        if notional > max_allowed_new_notional
          notional = max_allowed_new_notional
          quantity = notional / event.entry_price
        end
        
        next if quantity <= 0
        
        exit_bar_ts = event.exit_index && candles_by_symbol[symbol][event.exit_index] ? candles_by_symbol[symbol][event.exit_index][:ts] : event.entry_ts
        
        open_trades << {
          symbol: symbol,
          event: event,
          quantity: quantity.round(6),
          notional: notional.round(2),
          leverage: sizing.leverage_used,
          exit_ts: exit_bar_ts,
          bucket_key: bucket_key
        }
      rescue StandardError
      end
    end
    
    # Settle remaining
    open_trades.each do |open_trade|
      pnl_info = calculate_net_pnl(
        event: open_trade[:event],
        quantity: open_trade[:quantity],
        funding_series: funding_series_by_symbol[open_trade[:symbol]],
        bar_interval_minutes: bar_interval_mins
      )
      
      equity_usdt += pnl_info[:net_pnl_usdt]
      peak_equity_usdt = [peak_equity_usdt, equity_usdt].max
      dd = (peak_equity_usdt - equity_usdt) / peak_equity_usdt
      max_drawdown_pct = [max_drawdown_pct, dd].max
      
      trade_logs << BacktestSimulator::TradeLog.new(
        symbol: open_trade[:symbol],
        direction: open_trade[:event].direction,
        entry_ts: open_trade[:event].entry_ts,
        exit_ts: open_trade[:exit_ts],
        entry_price: open_trade[:event].entry_price,
        stop_price: open_trade[:event].stop_price,
        exit_price: open_trade[:event].exit_price,
        quantity: open_trade[:quantity],
        notional: open_trade[:notional],
        leverage: open_trade[:leverage],
        gross_pnl_usdt: pnl_info[:gross_pnl_usdt],
        fees_usdt: pnl_info[:fees_usdt],
        slippage_usdt: pnl_info[:slippage_usdt],
        funding_usdt: pnl_info[:funding_usdt],
        net_pnl_usdt: pnl_info[:net_pnl_usdt],
        net_pnl_inr: pnl_info[:net_pnl_usdt] * @exchange_rate_inr_usdt,
        ending_equity_usdt: equity_usdt,
        bucket_key: open_trade[:bucket_key]
      )
    end
    
    net_profit_usdt = equity_usdt - @starting_balance_usdt
    {
      starting_balance_inr: @starting_balance_inr,
      starting_balance_usdt: @starting_balance_usdt,
      final_balance_usdt: equity_usdt,
      final_balance_inr: equity_usdt * @exchange_rate_inr_usdt,
      net_profit_usdt: net_profit_usdt,
      net_profit_inr: net_profit_usdt * @exchange_rate_inr_usdt,
      net_profit_pct: (net_profit_usdt / @starting_balance_usdt) * 100.0,
      max_drawdown_pct: max_drawdown_pct * 100.0,
      total_trades: trade_logs.size,
      win_rate: trade_logs.empty? ? 0.0 : trade_logs.count { |t| t.net_pnl_usdt.positive? } / trade_logs.size.to_f,
      trades: trade_logs
    }
  end
end

# Calibration grid search for 2H candles
def calibrate_symbol_2h(symbol:, candles:, swings:, regimes:, funding_series:, extractor:, train_range:)
  profile = SymbolProfile.for(symbol)
  best_params = { stop_atr_buffer: 1.0, entry_delay_bars: 1, forward_horizon_bars: 20 }
  best_expectancy = -Float::INFINITY
  
  stops = [1.0, 1.5] # Constrained to wider stops to avoid overfitting wicks
  delays = [1, 3]
  horizons = [10, 20]
  
  stops.each do |stop|
    delays.each do |delay|
      horizons.each do |horz|
        labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: stop)
        
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
          stride: 3
        )
        
        buckets = SignatureAnalyzer.analyze(swing_events: events, baseline_samples: baselines)
        
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

scenarios = {
  baseline: {
    name: "Baseline Prior (Fixed 15m)",
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  },
  calibrated: {
    name: "Calibrated 2H (No Filter)",
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  },
  calibrated_mtf: {
    name: "Ultimate Composite Alpha (2H)",
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  }
}

puts "\nStarting Chronological Cash Backtest..."

folds_2h.each_with_index do |fold_2h, fold_idx|
  puts "\n--- FOLD #{fold_idx + 1} ---"
  
  test_start_ts = candles_2h_by_symbol[SYMBOLS.first][fold_2h.test_range.first][:ts]
  test_end_ts = candles_2h_by_symbol[SYMBOLS.first][fold_2h.test_range.max][:ts]
  
  # 1. Calibrate parameters on 2H train segments
  calibrated_params_2h = {}
  tradeable_buckets_2h = {}
  
  SYMBOLS.each do |symbol|
    candles = candles_2h_by_symbol[symbol]
    swings = swings_2h_by_symbol[symbol]
    regimes = regimes_2h_by_symbol[symbol]
    funding_series = funding_2h_by_symbol[symbol]
    extractor = extractor_2h_by_symbol[symbol]
    profile = SymbolProfile.for(symbol)
    
    params, edge = calibrate_symbol_2h(
      symbol: symbol, candles: candles, swings: swings, regimes: regimes,
      funding_series: funding_series, extractor: extractor, train_range: fold_2h.train_range
    )
    
    calibrated_params_2h[symbol] = params
    
    labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: params[:stop_atr_buffer])
    train_events = labeler.label_signal_events(
      candles: candles[0..fold_2h.train_range.end],
      swings: swings.select { |s| fold_2h.train_range.cover?(s.index) },
      regimes: regimes[0..fold_2h.train_range.end],
      funding_series: funding_series[0..fold_2h.train_range.end],
      feature_extractor: extractor,
      entry_delay_bars: params[:entry_delay_bars],
      forward_horizon_bars: params[:forward_horizon_bars]
    )
    
    train_baselines = labeler.label_baseline_samples(
      candles: candles[0..fold_2h.train_range.end],
      regimes: regimes[0..fold_2h.train_range.end],
      funding_series: funding_series[0..fold_2h.train_range.end],
      feature_extractor: extractor,
      forward_horizon_bars: params[:forward_horizon_bars],
      stride: 3
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
    
    tradeable_buckets_2h[symbol] = tradeable_buckets
    puts "  [#{symbol}] Calibrated 2H: stop=#{params[:stop_atr_buffer]} delay=#{params[:entry_delay_bars]} horizon=#{params[:forward_horizon_bars]} (edge=#{edge.round(3)})"
  end
  
  # Precompute training tradeable buckets for Baseline 15m
  baseline_tradeable_buckets_15m = {}
  SYMBOLS.each do |symbol|
    candles = candles_15m_by_symbol[symbol]
    swings = swings_15m_by_symbol[symbol]
    regimes = regimes_15m_by_symbol[symbol]
    funding_series = funding_15m_by_symbol[symbol]
    extractor = extractor_15m_by_symbol[symbol]
    profile = SymbolProfile.for(symbol)
    
    # We must find the corresponding training index in 15m series
    # fold_2h.train_range end timestamp:
    train_end_ts = candles_2h_by_symbol[symbol][fold_2h.train_range.end][:ts]
    train_15m_end_idx = candles.index { |c| c[:ts] <= train_end_ts } || (candles.size / 2)
    
    labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: 0.5)
    train_events = labeler.label_signal_events(
      candles: candles[0..train_15m_end_idx],
      swings: swings.select { |s| s.index <= train_15m_end_idx },
      regimes: regimes[0..train_15m_end_idx],
      funding_series: funding_series[0..train_15m_end_idx],
      feature_extractor: extractor,
      entry_delay_bars: 1,
      forward_horizon_bars: 20
    )
    
    train_baselines = labeler.label_baseline_samples(
      candles: candles[0..train_15m_end_idx],
      regimes: regimes[0..train_15m_end_idx],
      funding_series: funding_series[0..train_15m_end_idx],
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
    baseline_tradeable_buckets_15m[symbol] = tradeable_buckets
  end
  
  # 2. Execution phase on test fold OOS data
  
  # SCENARIO 1: Baseline 15m
  sim_baseline = GatedSimulator.new(
    starting_balance_inr: scenarios[:baseline][:compounded_balance_usdt] * EXCHANGE_RATE,
    exchange_rate_inr_usdt: EXCHANGE_RATE
  )
  res_baseline = sim_baseline.run_with_filter(
    candles_by_symbol: candles_15m_by_symbol,
    funding_series_by_symbol: funding_15m_by_symbol,
    swings_by_symbol: swings_15m_by_symbol,
    regimes_by_symbol: regimes_15m_by_symbol,
    feature_extractor_by_symbol: extractor_15m_by_symbol,
    tradeable_buckets_by_symbol: baseline_tradeable_buckets_15m,
    params_by_symbol: SYMBOLS.each_with_object({}) { |sym, h| h[sym] = { stop_atr_buffer: 0.5, entry_delay_bars: 1, forward_horizon_bars: 20 } },
    filter_proc: ->(e, h) { true },
    bar_interval_mins: 15
  )
  fold_trades_baseline = res_baseline[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
  scenarios[:baseline][:trades] += fold_trades_baseline
  scenarios[:baseline][:compounded_balance_usdt] += fold_trades_baseline.sum(&:net_pnl_usdt)
  
  # SCENARIO 2: Calibrated 2H (No Filter)
  sim_calibrated = GatedSimulator.new(
    starting_balance_inr: scenarios[:calibrated][:compounded_balance_usdt] * EXCHANGE_RATE,
    exchange_rate_inr_usdt: EXCHANGE_RATE
  )
  res_calibrated = sim_calibrated.run_with_filter(
    candles_by_symbol: candles_2h_by_symbol,
    funding_series_by_symbol: funding_2h_by_symbol,
    swings_by_symbol: swings_2h_by_symbol,
    regimes_by_symbol: regimes_2h_by_symbol,
    feature_extractor_by_symbol: extractor_2h_by_symbol,
    tradeable_buckets_by_symbol: tradeable_buckets_2h,
    params_by_symbol: calibrated_params_2h,
    filter_proc: ->(e, h) { true },
    bar_interval_mins: 120
  )
  fold_trades_calibrated = res_calibrated[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
  scenarios[:calibrated][:trades] += fold_trades_calibrated
  scenarios[:calibrated][:compounded_balance_usdt] += fold_trades_calibrated.sum(&:net_pnl_usdt)
  
  # SCENARIO 3: Ultimate Composite Alpha (Calibrated 2H + Volume Sweep + 4H Trend Alignment)
  sim_ultimate = GatedSimulator.new(
    starting_balance_inr: scenarios[:calibrated_mtf][:compounded_balance_usdt] * EXCHANGE_RATE,
    exchange_rate_inr_usdt: EXCHANGE_RATE
  )
  
  ultimate_filter = lambda do |event, aligned_htf|
    # 1. Volume Sweep Check (volume_zscore > 1.0)
    return false unless event.context[:volume_zscore] && event.context[:volume_zscore] > 1.0
    
    # 2. 4H Trend Alignment Check
    htf_reg = aligned_htf ? aligned_htf[event.entry_index] : nil
    if htf_reg
      if htf_reg.state == :trending_bull && event.direction != :long
        return false
      elsif htf_reg.state == :trending_bear && event.direction != :short
        return false
      end
    end
    true
  end
  
  res_ultimate = sim_ultimate.run_with_filter(
    candles_by_symbol: candles_2h_by_symbol,
    funding_series_by_symbol: funding_2h_by_symbol,
    swings_by_symbol: swings_2h_by_symbol,
    regimes_by_symbol: regimes_2h_by_symbol,
    feature_extractor_by_symbol: extractor_2h_by_symbol,
    tradeable_buckets_by_symbol: tradeable_buckets_2h,
    params_by_symbol: calibrated_params_2h,
    aligned_htf_by_symbol: aligned_4h_regimes_by_symbol,
    filter_proc: ultimate_filter,
    bar_interval_mins: 120
  )
  fold_trades_ultimate = res_ultimate[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
  scenarios[:calibrated_mtf][:trades] += fold_trades_ultimate
  scenarios[:calibrated_mtf][:compounded_balance_usdt] += fold_trades_ultimate.sum(&:net_pnl_usdt)
  
  # Record equity curve points at end of fold
  scenarios.each do |key, sc|
    sc[:equity_curve] << {
      fold: fold_idx + 1,
      timestamp: test_end_ts,
      balance_inr: (sc[:compounded_balance_usdt] * EXCHANGE_RATE).round(2),
      trades_in_fold: case key
                      when :baseline then fold_trades_baseline.size
                      when :calibrated then fold_trades_calibrated.size
                      when :calibrated_mtf then fold_trades_ultimate.size
                      end
    }
  end
  
  puts "  Baseline 15m: trades=#{fold_trades_baseline.size}  net_pnl=#{(fold_trades_baseline.sum(&:net_pnl_usdt) * EXCHANGE_RATE).round(2)} INR  (Ending: #{(scenarios[:baseline][:compounded_balance_usdt] * EXCHANGE_RATE).round(2)} INR)"
  puts "  Calib 2H:     trades=#{fold_trades_calibrated.size}  net_pnl=#{(fold_trades_calibrated.sum(&:net_pnl_usdt) * EXCHANGE_RATE).round(2)} INR  (Ending: #{(scenarios[:calibrated][:compounded_balance_usdt] * EXCHANGE_RATE).round(2)} INR)"
  puts "  Ultimate 2H:  trades=#{fold_trades_ultimate.size}  net_pnl=#{(fold_trades_ultimate.sum(&:net_pnl_usdt) * EXCHANGE_RATE).round(2)} INR  (Ending: #{(scenarios[:calibrated_mtf][:compounded_balance_usdt] * EXCHANGE_RATE).round(2)} INR)"
end

# Calculate aggregate results & prepare export payload
export_payload = {}

puts "\n" + "=" * 70
puts "COMPARATIVE SCENARIO REPORT"
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
  
  # Sharpe Ratio
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

# Write payload to JSON
results_path = File.join(root, "data", "backtest_results.json")
File.write(results_path, JSON.pretty_generate(export_payload))
puts "\nResults written to #{results_path} successfully."

# Compile HTML dashboard with inline data
template_path = File.join(root, "data", "dashboard_template.html")
if File.exist?(template_path)
  template_content = File.read(template_path)
  compiled_content = template_content.gsub(
    "// INSERT_BACKTEST_DATA_HERE",
    "window.backtestData = #{JSON.dump(export_payload)};"
  )
  compiled_content = compiled_content.gsub(
    "<h3>Calibrated + 1h MTF Align</h3>",
    "<h3>Ultimate Composite Alpha (2H)</h3>"
  )
  compiled_content = compiled_content.gsub(
    "<h3>Walk-Forward Calibrated</h3>",
    "<h3>Calibrated 2H (No Filter)</h3>"
  )
  compiled_content = compiled_content.gsub(
    "<h3>Baseline Prior (Fixed)</h3>",
    "<h3>Baseline Prior (Fixed 15m)</h3>"
  )
  compiled_content = compiled_content.gsub(
    "<h1>Crypto perp futures backtest analytics</h1>",
    "<h1>Ultimate Composite Alpha Backtest Analytics</h1>"
  )
  compiled_content = compiled_content.gsub(
    "<p>Walk-forward calibration & multi-timeframe strategy evaluation</p>",
    "<p>Evaluating Baseline 15m vs Calibrated 2H vs Gated Ultimate Composite 2H strategy</p>"
  )
  
  dashboard_path = File.join(root, "data", "backtest_dashboard.html")
  File.write(dashboard_path, compiled_content)
  puts "HTML Dashboard compiled to #{dashboard_path} with embedded backtest data."
else
  puts "WARNING: dashboard_template.html not found at #{template_path}"
end

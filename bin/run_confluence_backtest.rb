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
require_relative "../lib/strategy_engine"

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
INTERVAL = "15m"
DAYS_BACK = 90
WALK_FORWARD_FOLDS = 6
EMBARGO_BARS_2H = 3
CACHE_DIR = File.join(root, "data", "cache")

STARTING_BALANCE_INR = 100_000.0
EXCHANGE_RATE = 83.5 # INR/USDT

# Subclass StrategyEngine to run optimized evaluations on full series
class FastStrategyEngine < StrategyEngine
  def set_precomputed(regimes, ema_fast)
    @regimes_pre = regimes
    @ema_fast_pre = ema_fast
  end

  def evaluate_fast(candles:, index:, funding_rate:, account_equity: nil, risk_pct: 0.01)
    regime = @regimes_pre[index]
    ema_fast_val = @ema_fast_pre[index]
    candle = candles[index]
    return nil if regime.nil? || ema_fast_val.nil?

    trend = @trend_signal.evaluate(
      regime: regime, candle: candle, ema_fast_val: ema_fast_val, ema_slow_val: nil
    )
    structure = @structure_signal.evaluate(candles: candles[0..index], index: index)
    funding = @funding_signal.evaluate(funding_rate: funding_rate)

    candidate = @scorer.score(trend: trend, structure: structure, funding: funding)

    sizing = nil
    if candidate.direction != :none && account_equity
      stop_price = structural_stop(candles: candles[0..index], index: index, direction: candidate.direction)
      sizing = @sizer.size(
        account_equity: account_equity, entry_price: candle[:close],
        stop_price: stop_price, risk_pct: risk_pct, direction: candidate.direction
      )
    end

    StrategyEngine::Evaluation.new(symbol: @symbol, timestamp: candle[:ts], regime: regime, candidate: candidate, sizing: sizing)
  end
end

# 1. Load raw 15m data and resample to 2H
candles_2h_by_symbol = {}
funding_2h_by_symbol = {}
regimes_2h_by_symbol = {}
swings_2h_by_symbol = {}
extractor_2h_by_symbol = {}
ema_fast_2h_by_symbol = {}

puts "======================================================================"
puts "MULTI-SIGNAL CONFLUENCE VS SWING REVERSAL RESEARCH RUNNER"
puts "======================================================================"

SYMBOLS.each do |symbol|
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_#{DAYS_BACK}d.json")))
  
  candles_15m = BinanceDataLoader.klines_to_candles(raw_klines)
  candles_2h = CandleResampler.resample_candles(candles_15m, 8)
  funding_2h = BinanceDataLoader.align_funding_series(candles_2h, raw_funding)
  
  profile = SymbolProfile.for(symbol)
  regimes_2h = RegimeClassifier.new(profile).classify(candles_2h)
  swings_2h = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles_2h)
  
  extractor_2h = ContextFeatureExtractor.new(profile)
  closes_2h = candles_2h.map { |c| c[:close] }
  ema_fast = Indicators.ema(closes_2h, profile.ema_fast)
  extractor_2h.ema_cache_fast = ema_fast
  extractor_2h.ema_cache_slow = Indicators.ema(closes_2h, profile.ema_slow)
  extractor_2h.rsi_cache = Indicators.rsi(candles_2h, 14)
  
  candles_2h_by_symbol[symbol] = candles_2h
  funding_2h_by_symbol[symbol] = funding_2h
  regimes_2h_by_symbol[symbol] = regimes_2h
  swings_2h_by_symbol[symbol] = swings_2h
  extractor_2h_by_symbol[symbol] = extractor_2h
  ema_fast_2h_by_symbol[symbol] = ema_fast
  
  puts "#{symbol}: Resampled to 2H candles."
end

# Build folds based on 2H candle count
total_bars_2h = candles_2h_by_symbol[SYMBOLS.first].size
folds_2h = WalkForwardValidator.build_folds(total_bars: total_bars_2h, n_folds: WALK_FORWARD_FOLDS, embargo_bars: EMBARGO_BARS_2H)

scenarios = {
  swing_reversal: {
    name: "Swing Reversal (Calibrated 2H)",
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  },
  confluence: {
    name: "Multi-Signal Confluence (2H)",
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  }
}

# TradeLog format helper
TradeLog = Struct.new(
  :symbol, :direction, :entry_ts, :exit_ts, :entry_price, :stop_price, :exit_price,
  :quantity, :notional, :leverage, :net_pnl_usdt, :net_pnl_inr, :ending_equity_usdt, :bucket_key,
  keyword_init: true
)

# Funding carry rate calculator
def get_carry_fees(symbol, direction, quantity, entry_ts, exit_ts, funding_series, candles)
  # Find indices in candles
  idx_start = candles.index { |c| c[:ts] >= entry_ts } || 0
  idx_end = candles.index { |c| c[:ts] >= exit_ts } || (candles.size - 1)
  
  total_carry = 0.0
  (idx_start..idx_end).each do |i|
    rate = funding_series[i] || 0.0
    next if rate.zero?
    
    # 8-hourly funding rate, resampled to 2H (prorated 25%)
    prorated = rate * 0.25
    mark_price = candles[i][:close]
    notional = quantity * mark_price
    
    carry = direction == :long ? -notional * prorated : notional * prorated
    total_carry += carry
  end
  total_carry
end

# Calibration for Swing Reversal (returns parameters & tradeable buckets)
def calibrate_swing_reversal(symbol, candles, swings, regimes, funding_series, extractor, fold)
  profile = SymbolProfile.for(symbol)
  labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: 1.0)
  
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
    stride: 3
  )
  
  buckets = SignatureAnalyzer.analyze(swing_events: train_events, baseline_samples: train_baselines)
  
  tradeable = {}
  buckets.each do |bucket|
    plan = DynamicRiskPlanner.plan(bucket_stats: bucket)
    next unless plan.tradeable
    
    bucket_events = train_events.select { |e| e.context[:regime_state] == bucket.bucket_key }
    dir = bucket_events.group_by(&:direction).max_by { |_, v| v.size }&.first
    next if dir.nil?
    
    tradeable[bucket.bucket_key] = { plan: plan, direction: dir }
  end
  tradeable
end

puts "\nSimulating walk-forward out-of-sample execution..."

folds_2h.each_with_index do |fold, fold_idx|
  puts "  Fold #{fold_idx + 1}/#{WALK_FORWARD_FOLDS}..."
  
  test_start_ts = candles_2h_by_symbol[SYMBOLS.first][fold.test_range.first][:ts]
  test_end_ts = candles_2h_by_symbol[SYMBOLS.first][fold.test_range.max][:ts]
  
  # A. Run Swing Reversal
  tradeable_swing_by_symbol = SYMBOLS.each_with_object({}) do |sym, h|
    h[sym] = calibrate_swing_reversal(
      sym, candles_2h_by_symbol[sym], swings_2h_by_symbol[sym],
      regimes_2h_by_symbol[sym], funding_2h_by_symbol[sym], extractor_2h_by_symbol[sym], fold
    )
  end
  
  sim_swing = BacktestSimulator.new(
    starting_balance_inr: scenarios[:swing_reversal][:compounded_balance_usdt] * EXCHANGE_RATE,
    exchange_rate_inr_usdt: EXCHANGE_RATE
  )
  
  res_swing = sim_swing.run(
    candles_by_symbol: candles_2h_by_symbol,
    funding_series_by_symbol: funding_2h_by_symbol,
    swings_by_symbol: swings_2h_by_symbol,
    regimes_by_symbol: regimes_2h_by_symbol,
    feature_extractor_by_symbol: extractor_2h_by_symbol,
    tradeable_buckets_by_symbol: tradeable_swing_by_symbol,
    params_by_symbol: SYMBOLS.each_with_object({}) { |sym, h| h[sym] = { stop_atr_buffer: 1.0, entry_delay_bars: 1, forward_horizon_bars: 20 } }
  )
  
  fold_trades_swing = res_swing[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
  scenarios[:swing_reversal][:trades] += fold_trades_swing
  scenarios[:swing_reversal][:compounded_balance_usdt] += fold_trades_swing.sum(&:net_pnl_usdt)
  
  # B. Run Confluence Strategy
  # Instantiate FastStrategyEngine per symbol
  engines = SYMBOLS.each_with_object({}) do |sym, h|
    eng = FastStrategyEngine.new(sym)
    eng.set_precomputed(regimes_2h_by_symbol[sym], ema_fast_2h_by_symbol[sym])
    h[sym] = eng
  end
  
  # Collect all confluence candidates in the test range
  confluence_events = []
  
  SYMBOLS.each do |symbol|
    candles = candles_2h_by_symbol[symbol]
    funding = funding_2h_by_symbol[symbol]
    engine = engines[symbol]
    profile = SymbolProfile.for(symbol)
    
    fold.test_range.each do |idx|
      eval_res = engine.evaluate_fast(
        candles: candles, index: idx, funding_rate: funding[idx],
        account_equity: scenarios[:confluence][:compounded_balance_usdt],
        risk_pct: 0.01
      )
      next if eval_res.nil? || eval_res.candidate.direction == :none
      
      # Determine structural stop
      stop_price = eval_res.sizing.stop_price
      entry_price = candles[idx][:close]
      stop_dist = (entry_price - stop_price).abs
      next if stop_dist.zero?
      
      # Determine target price (R=2.0)
      target_price = eval_res.candidate.direction == :long ? entry_price + stop_dist * 2.0 : entry_price - stop_dist * 2.0
      
      # Simulate trade outcome
      exit_idx, exit_price, r_multiple = nil, nil, nil
      last_bar = [idx + 20, candles.size - 1].min
      ((idx + 1)..last_bar).each do |i|
        bar = candles[i]
        if eval_res.candidate.direction == :long
          if bar[:low] <= stop_price
            exit_idx, exit_price, r_multiple = i, stop_price, -1.0
            break
          elsif bar[:high] >= target_price
            exit_idx, exit_price, r_multiple = i, target_price, 2.0
            break
          end
        else
          if bar[:high] >= stop_price
            exit_idx, exit_price, r_multiple = i, stop_price, -1.0
            break
          elsif bar[:low] <= target_price
            exit_idx, exit_price, r_multiple = i, target_price, 2.0
            break
          end
        end
      end
      
      unless exit_idx
        exit_idx = last_bar
        exit_price = candles[last_bar][:close]
        move = eval_res.candidate.direction == :long ? exit_price - entry_price : entry_price - exit_price
        r_multiple = move / stop_dist
      end
      
      confluence_events << {
        symbol: symbol,
        direction: eval_res.candidate.direction,
        entry_ts: candles[idx][:ts],
        exit_ts: candles[exit_idx][:ts],
        entry_price: entry_price,
        stop_price: stop_price,
        exit_price: exit_price,
        r_multiple: r_multiple,
        sizing: eval_res.sizing,
        bucket_key: eval_res.regime.state.to_s
      }
    end
  end
  
  # Chronological trade simulation for Confluence
  confluence_events.sort_by! { |e| e[:entry_ts] }
  equity_usdt = scenarios[:confluence][:compounded_balance_usdt]
  peak_equity_usdt = equity_usdt
  max_dd_pct = 0.0
  
  open_trades = []
  fold_trades_confluence = []
  
  confluence_events.each do |e|
    symbol = e[:symbol]
    candles = candles_2h_by_symbol[symbol]
    funding = funding_2h_by_symbol[symbol]
    profile = SymbolProfile.for(symbol)
    
    # Settle trades
    open_trades.reject! do |ot|
      if ot[:exit_ts] <= e[:entry_ts]
        # P&L calculations
        move = ot[:direction] == :long ? ot[:exit_price] - ot[:entry_price] : ot[:entry_price] - ot[:exit_price]
        gross_pnl = ot[:quantity] * move
        
        # Fees (4 bps entry, 4 bps exit)
        fees = (ot[:entry_price] + ot[:exit_price]) * ot[:quantity] * 0.0004
        # Slippage (2 bps entry, 2 bps exit)
        slippage = (ot[:entry_price] + ot[:exit_price]) * ot[:quantity] * 0.0002
        # Funding Carry (prorated 2H)
        funding_fee = get_carry_fees(ot[:symbol], ot[:direction], ot[:quantity], ot[:entry_ts], ot[:exit_ts], funding, candles)
        
        net_pnl = gross_pnl - fees - slippage + funding_fee
        equity_usdt += net_pnl
        peak_equity_usdt = [peak_equity_usdt, equity_usdt].max
        
        fold_trades_confluence << TradeLog.new(
          symbol: ot[:symbol], direction: ot[:direction], entry_ts: ot[:entry_ts], exit_ts: ot[:exit_ts],
          entry_price: ot[:entry_price], stop_price: ot[:stop_price], exit_price: ot[:exit_price],
          quantity: ot[:quantity], notional: ot[:notional], leverage: ot[:leverage],
          net_pnl_usdt: net_pnl, net_pnl_inr: net_pnl * EXCHANGE_RATE, ending_equity_usdt: equity_usdt,
          bucket_key: ot[:bucket_key]
        )
        true
      else
        false
      end
    end
    
    # Size and place new trade
    risk_pct = 0.01
    current_notional = open_trades.sum { |ot| ot[:notional] }
    max_notional = (equity_usdt * profile.max_leverage) - current_notional
    next if max_notional <= 0
    
    sizing = e[:sizing]
    qty = sizing.quantity
    notional = sizing.notional
    if notional > max_notional
      notional = max_notional
      qty = notional / e[:entry_price]
    end
    next if qty <= 0
    
    open_trades << {
      symbol: symbol, direction: e[:direction], entry_ts: e[:entry_ts], exit_ts: e[:exit_ts],
      entry_price: e[:entry_price], stop_price: e[:stop_price], exit_price: e[:exit_price],
      quantity: qty.round(6), notional: notional.round(2), leverage: sizing.leverage_used,
      bucket_key: e[:bucket_key]
    }
  end
  
  # Settle remaining
  open_trades.each do |ot|
    symbol = ot[:symbol]
    candles = candles_2h_by_symbol[symbol]
    funding = funding_2h_by_symbol[symbol]
    
    move = ot[:direction] == :long ? ot[:exit_price] - ot[:entry_price] : ot[:entry_price] - ot[:exit_price]
    gross_pnl = ot[:quantity] * move
    fees = (ot[:entry_price] + ot[:exit_price]) * ot[:quantity] * 0.0004
    slippage = (ot[:entry_price] + ot[:exit_price]) * ot[:quantity] * 0.0002
    funding_fee = get_carry_fees(ot[:symbol], ot[:direction], ot[:quantity], ot[:entry_ts], ot[:exit_ts], funding, candles)
    
    net_pnl = gross_pnl - fees - slippage + funding_fee
    equity_usdt += net_pnl
    
    fold_trades_confluence << TradeLog.new(
      symbol: ot[:symbol], direction: ot[:direction], entry_ts: ot[:entry_ts], exit_ts: ot[:exit_ts],
      entry_price: ot[:entry_price], stop_price: ot[:stop_price], exit_price: ot[:exit_price],
      quantity: ot[:quantity], notional: ot[:notional], leverage: ot[:leverage],
      net_pnl_usdt: net_pnl, net_pnl_inr: net_pnl * EXCHANGE_RATE, ending_equity_usdt: equity_usdt,
      bucket_key: ot[:bucket_key]
    )
  end
  
  scenarios[:confluence][:trades] += fold_trades_confluence
  scenarios[:confluence][:compounded_balance_usdt] = equity_usdt
  
  scenarios.each do |key, sc|
    sc[:equity_curve] << {
      fold: fold_idx + 1,
      timestamp: test_end_ts,
      balance_inr: (sc[:compounded_balance_usdt] * EXCHANGE_RATE).round(2),
      trades_in_fold: key == :swing_reversal ? fold_trades_swing.size : fold_trades_confluence.size
    }
  end
  
  puts "    Swing Reversal: #{fold_trades_swing.size} trades, ending=#{(scenarios[:swing_reversal][:compounded_balance_usdt] * EXCHANGE_RATE).round(2)} INR"
  puts "    Confluence:     #{fold_trades_confluence.size} trades, ending=#{(scenarios[:confluence][:compounded_balance_usdt] * EXCHANGE_RATE).round(2)} INR"
end

# Calculate aggregate results & prepare export payload
export_payload = {}

puts "\n" + "=" * 70
puts "STRATEGY COMPARATIVE LEADERBOARD"
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
    "<h3>Multi-Signal Confluence (2H)</h3>"
  )
  compiled_content = compiled_content.gsub(
    "<h3>Walk-Forward Calibrated</h3>",
    "<h3>Swing Reversal (Calibrated 2H)</h3>"
  )
  
  # Remove baseline from template UI since we only compare these two
  compiled_content = compiled_content.gsub(
    /<div class="strategy-card" data-strategy="baseline">[\s\S]*?<\/div>/,
    ""
  )
  
  compiled_content = compiled_content.gsub(
    "<h1>Crypto perp futures backtest analytics</h1>",
    "<h1>Multi-Strategy Alpha Comparison Dashboard</h1>"
  )
  compiled_content = compiled_content.gsub(
    "<p>Walk-forward calibration & multi-timeframe strategy evaluation</p>",
    "<p>Evaluating Swing Reversal vs Confluence Strategy (SMC Structure + Trend + Carry) on 2H candles</p>"
  )
  
  dashboard_path = File.join(root, "data", "backtest_dashboard_confluence.html")
  File.write(dashboard_path, compiled_content)
  puts "HTML Dashboard compiled to #{dashboard_path} with embedded confluence research data."
else
  puts "WARNING: dashboard_template.html not found at #{template_path}"
end

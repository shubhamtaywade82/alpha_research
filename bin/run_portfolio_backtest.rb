#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"

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

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
INTERVAL = "15m"
DAYS_BACK = 90
WALK_FORWARD_FOLDS = 6
EMBARGO_BARS = 20
CACHE_DIR = File.join(root, "data", "cache")

STARTING_BALANCE_INR = 100_000.0
EXCHANGE_RATE = 83.5 # INR/USDT

# 1. Load data for all symbols
candles_by_symbol = {}
funding_series_by_symbol = {}
regimes_by_symbol = {}
swings_by_symbol = {}
feature_extractor_by_symbol = {}

puts "======================================================================"
require "time"
puts "PORTFOLIO BACKTEST SIMULATOR (Starting Balance: #{STARTING_BALANCE_INR} INR / #{(STARTING_BALANCE_INR/EXCHANGE_RATE).round(2)} USDT)"
puts "======================================================================"

SYMBOLS.each do |symbol|
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_#{DAYS_BACK}d.json")))
  
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  profile = SymbolProfile.for(symbol)
  
  regimes = RegimeClassifier.new(profile).classify(candles)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  extractor = ContextFeatureExtractor.new(profile)
  
  # Warm up caches
  closes = candles.map { |c| c[:close] }
  extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
  extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)
  
  candles_by_symbol[symbol] = candles
  funding_series_by_symbol[symbol] = funding_series
  regimes_by_symbol[symbol] = regimes
  swings_by_symbol[symbol] = swings
  feature_extractor_by_symbol[symbol] = extractor
  
  puts "#{symbol}: #{candles.size} candles, #{swings.size} swings"
end

# Build folds
total_bars = candles_by_symbol[SYMBOLS.first].size
folds = WalkForwardValidator.build_folds(total_bars: total_bars, n_folds: WALK_FORWARD_FOLDS, embargo_bars: EMBARGO_BARS)

# We will run the backtest chronologically fold-by-fold
current_balance_usdt = STARTING_BALANCE_INR / EXCHANGE_RATE
all_trades = []

puts "\nStarting Walk-Forward Cash Simulation over #{folds.size} folds..."

folds.each_with_index do |fold, fold_idx|
  puts "\n--- FOLD #{fold_idx + 1} ---"
  
  # A. Determine tradeable buckets for each symbol on the TRAIN segment of this fold
  tradeable_buckets_by_symbol = {}
  
  SYMBOLS.each do |symbol|
    candles = candles_by_symbol[symbol]
    swings = swings_by_symbol[symbol]
    regimes = regimes_by_symbol[symbol]
    funding_series = funding_series_by_symbol[symbol]
    extractor = feature_extractor_by_symbol[symbol]
    profile = SymbolProfile.for(symbol)
    
    labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: 1.0)
    
    # Train range events
    train_events = labeler.label_signal_events(
      candles: candles[0..fold.train_range.end],
      swings: swings.select { |s| fold.train_range.cover?(s.index) },
      regimes: regimes[0..fold.train_range.end],
      funding_series: funding_series[0..fold.train_range.end],
      feature_extractor: extractor,
      entry_delay_bars: 3,
      forward_horizon_bars: 10
    )
    
    train_baselines = labeler.label_baseline_samples(
      candles: candles[0..fold.train_range.end],
      regimes: regimes[0..fold.train_range.end],
      funding_series: funding_series[0..fold.train_range.end],
      feature_extractor: extractor,
      forward_horizon_bars: 10,
      stride: 5
    )
    
    buckets = SignatureAnalyzer.analyze(swing_events: train_events, baseline_samples: train_baselines)
    
    tradeable_buckets = {}
    buckets.each do |bucket|
      plan = DynamicRiskPlanner.plan(bucket_stats: bucket)
      next unless plan.tradeable
      
      # Determine dominant direction on train
      bucket_events = train_events.select { |e| e.context[:regime_state] == bucket.bucket_key }
      dominant_direction = bucket_events.group_by(&:direction).max_by { |_, v| v.size }&.first
      next if dominant_direction.nil?
      
      tradeable_buckets[bucket.bucket_key] = { plan: plan, direction: dominant_direction }
      puts "  [#{symbol}] Tradeable: #{bucket.bucket_key} dir=#{dominant_direction} edge=#{bucket.edge_over_baseline} risk=#{plan.risk_pct}"
    end
    
    tradeable_buckets_by_symbol[symbol] = tradeable_buckets
  end
  
  # B. Prepare OOS test data for the simulator
  test_candles = {}
  test_funding = {}
  test_swings = {}
  test_regimes = {}
  test_extractor = {}
  
  SYMBOLS.each do |symbol|
    test_candles[symbol] = candles_by_symbol[symbol][fold.test_range]
    test_funding[symbol] = funding_series_by_symbol[symbol][fold.test_range]
    test_swings[symbol] = swings_by_symbol[symbol].select { |s| fold.test_range.cover?(s.confirmed_index + 1) } # confirmation index + delay lands inside test
    test_regimes[symbol] = regimes_by_symbol[symbol][fold.test_range]
    test_extractor[symbol] = feature_extractor_by_symbol[symbol]
  end
  
  # C. Run simulator on OOS test segment
  simulator = BacktestSimulator.new(
    starting_balance_inr: current_balance_usdt * EXCHANGE_RATE,
    exchange_rate_inr_usdt: EXCHANGE_RATE,
    fee_bps_per_side: 4.0,
    slippage_bps_per_side: 2.0
  )
  
  # To map the indexing correctly inside the simulator, we pass full series but the simulator evaluates only events whose entries land within the test range.
  # Let's adjust simulator call:
  tradeable_events_in_test_range = {}
  
  fold_result = simulator.run(
    candles_by_symbol: candles_by_symbol,
    funding_series_by_symbol: funding_series_by_symbol,
    swings_by_symbol: swings_by_symbol,
    regimes_by_symbol: regimes_by_symbol,
    feature_extractor_by_symbol: feature_extractor_by_symbol,
    tradeable_buckets_by_symbol: tradeable_buckets_by_symbol,
    entry_delay_bars: 3,
    forward_horizon_bars: 10
  )
  
  # Filter trades that actually entered during this fold's test range
  test_start_ts = candles_by_symbol[SYMBOLS.first][fold.test_range.first][:ts]
  test_end_ts = candles_by_symbol[SYMBOLS.first][fold.test_range.max][:ts]
  
  fold_trades = fold_result[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
  all_trades += fold_trades
  
  fold_net_profit_usdt = fold_trades.sum(&:net_pnl_usdt)
  current_balance_usdt += fold_net_profit_usdt
  
  puts "  Fold Results: trades=#{fold_trades.size} win_rate=#{(fold_trades.empty? ? 0.0 : (fold_trades.count { |t| t.net_pnl_usdt.positive? } / fold_trades.size.to_f * 100.0)).round(1)}% net_pnl=#{(fold_net_profit_usdt * EXCHANGE_RATE).round(2)} INR (Ending Balance: #{(current_balance_usdt * EXCHANGE_RATE).round(2)} INR)"
end

# 3. Print final report
total_trades = all_trades.size
winning_trades = all_trades.count { |t| t.net_pnl_usdt.positive? }
win_rate = total_trades.positive? ? (winning_trades.to_f / total_trades) : 0.0

total_net_pnl_usdt = current_balance_usdt - (STARTING_BALANCE_INR / EXCHANGE_RATE)
total_net_pnl_inr = total_net_pnl_usdt * EXCHANGE_RATE
total_net_pnl_pct = (total_net_pnl_usdt / (STARTING_BALANCE_INR / EXCHANGE_RATE)) * 100.0

# Drawdown calculation across the trade series
running_equity = STARTING_BALANCE_INR / EXCHANGE_RATE
peak_equity = running_equity
max_dd_pct = 0.0

all_trades.sort_by!(&:entry_ts).each do |t|
  running_equity += t.net_pnl_usdt
  peak_equity = [peak_equity, running_equity].max
  dd = (peak_equity - running_equity) / peak_equity
  max_dd_pct = [max_dd_pct, dd].max
end

puts "\n" + "=" * 70
puts "FINAL PORTFOLIO BACKTEST REPORT"
puts "=" * 70
puts "Starting Balance : #{STARTING_BALANCE_INR.round(2)} INR"
puts "Final Balance    : #{(current_balance_usdt * EXCHANGE_RATE).round(2)} INR (#{(current_balance_usdt).round(2)} USDT)"
puts "Total Net Profit : #{total_net_pnl_inr.round(2)} INR  (#{total_net_pnl_pct.round(2)}%)"
puts "Total Trades     : #{total_trades}"
puts "Win Rate         : #{(win_rate * 100.0).round(2)}%  (#{winning_trades} wins, #{total_trades - winning_trades} losses)"
puts "Max Drawdown     : #{(max_dd_pct * 100.0).round(2)}%"

# Breakdown by Symbol
puts "\n== Performance by Symbol =="
puts format("%-10s %6s %10s %8s", "Symbol", "Trades", "Net Profit (INR)", "Win Rate")
SYMBOLS.each do |symbol|
  sym_trades = all_trades.select { |t| t.symbol == symbol }
  sym_pnl = sym_trades.sum(&:net_pnl_usdt) * EXCHANGE_RATE
  sym_wr = sym_trades.empty? ? 0.0 : sym_trades.count { |t| t.net_pnl_usdt.positive? } / sym_trades.size.to_f
  puts format("%-10s %6d %15.2f %7.1f%%", symbol, sym_trades.size, sym_pnl, sym_wr * 100.0)
end

# Breakdown by Regime
puts "\n== Performance by Market Context (Regime) =="
puts format("%-20s %6s %10s %8s", "Regime", "Trades", "Net Profit (INR)", "Win Rate")
all_regimes = all_trades.map(&:bucket_key).uniq.compact
all_regimes.each do |regime|
  reg_trades = all_trades.select { |t| t.bucket_key == regime }
  reg_pnl = reg_trades.sum(&:net_pnl_usdt) * EXCHANGE_RATE
  reg_wr = reg_trades.empty? ? 0.0 : reg_trades.count { |t| t.net_pnl_usdt.positive? } / reg_trades.size.to_f
  puts format("%-20s %6d %15.2f %7.1f%%", regime, reg_trades.size, reg_pnl, reg_wr * 100.0)
end

# Output top trades
puts "\n== Top 10 Trades by Net Profit =="
puts format("%-10s %-5s %-16s %-16s %8s %12s", "Symbol", "Dir", "Entry Time", "Exit Time", "Leverage", "Net P&L (INR)")
all_trades.sort_by { |t| -t.net_pnl_usdt }.first(10).each do |t|
  puts format("%-10s %-5s %-16s %-16s %8.2f %12.2f",
              t.symbol, t.direction, Time.at(t.entry_ts).strftime("%m-%d %H:%M"),
              Time.at(t.exit_ts).strftime("%m-%d %H:%M"), t.leverage, t.net_pnl_inr)
end

puts "\nBacktest complete."

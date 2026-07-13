#!/usr/bin/env ruby
# frozen_string_literal: true

# Run locally (NOT in a datacenter/cloud sandbox — Binance mainnet 451s
# those). Requires only Ruby stdlib, no gems, no API key/secret.
#
#   ruby bin/run_real_data_analysis.rb
#
# Set FORCE_REFRESH=1 to bypass the local cache and re-pull from Binance:
#   FORCE_REFRESH=1 ruby bin/run_real_data_analysis.rb
#
# Adjust SYMBOLS / INTERVAL / DAYS_BACK below as needed.

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
require_relative "../lib/trade_cost_model"
require_relative "../lib/walk_forward_discovery_evaluator"

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
INTERVAL = "15m"
DAYS_BACK = 90
WALK_FORWARD_FOLDS = 6
EMBARGO_BARS = 20
FEE_BPS_PER_SIDE = 4.0
SLIPPAGE_BPS_PER_SIDE = 2.0
CACHE_DIR = File.join(root, "data", "cache")
FileUtils.mkdir_p(CACHE_DIR)

def cached_fetch(cache_key)
  path = File.join(CACHE_DIR, "#{cache_key}.json")
  if !ENV["FORCE_REFRESH"] && File.exist?(path)
    puts "  [cache] #{cache_key}"
    return JSON.parse(File.read(path))
  end

  puts "  [fetching] #{cache_key}"
  data = yield
  File.write(path, JSON.generate(data))
  data
end

def print_bucket_table(label, buckets)
  puts "\n-- #{label} --"
  puts format("%-16s %6s %10s %10s %10s %10s", "regime", "n", "mean_r", "win_rate", "baseline_r", "edge")
  buckets.sort_by { |b| -(b.swing_count) }.each do |b|
    puts format("%-16s %6d %10s %10s %10s %10s",
                 b.bucket_key, b.swing_count, b.swing_mean_r.inspect, b.swing_win_rate.inspect,
                 b.baseline_mean_r.inspect, b.edge_over_baseline.inspect)
  end
end

def print_walk_forward_summary(label, result)
  puts "\n-- #{label} --"
  aggregate = result[:aggregate]
  if aggregate[:note]
    puts aggregate[:note]
    return
  end

  puts format("%-6s %-8s %-10s %-10s %-10s %-10s %-10s", "fold", "trades", "gross_r", "net_r", "baseline", "alpha", "win_rate")
  result[:folds].each_with_index do |fold, idx|
    puts format("%-6d %-8d %-10s %-10s %-10s %-10s %-10s",
                idx + 1, fold.trade_count, fold.gross_expectancy_r.inspect,
                fold.net_expectancy_r.inspect, fold.baseline_net_expectancy_r.inspect,
                fold.alpha_net_r.inspect, fold.win_rate.inspect)
  end

  puts "aggregate: trades=#{aggregate[:total_trades]} gross_r=#{aggregate[:mean_gross_expectancy_r].inspect} " \
       "net_r=#{aggregate[:mean_net_expectancy_r].inspect} baseline=#{aggregate[:mean_baseline_net_expectancy_r].inspect} " \
       "alpha=#{aggregate[:mean_alpha_net_r].inspect} win_rate=#{aggregate[:mean_win_rate].inspect}"
end

SYMBOLS.each do |symbol|
  puts "\n#{'=' * 70}"
  puts "#{symbol}  (#{INTERVAL}, last #{DAYS_BACK}d, mainnet)"
  puts "=" * 70

  raw_klines = cached_fetch("#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d") do
    BinanceDataLoader.fetch_klines(symbol: symbol, interval: INTERVAL, days_back: DAYS_BACK)
  end
  raw_funding = cached_fetch("#{symbol}_funding_#{DAYS_BACK}d") do
    BinanceDataLoader.fetch_funding_rate_history(symbol: symbol, days_back: DAYS_BACK)
  end

  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  puts "#{candles.size} candles loaded (#{Time.at(candles.first[:ts])} -> #{Time.at(candles.last[:ts])})"

  profile = SymbolProfile.for(symbol)
  regimes = RegimeClassifier.new(profile).classify(candles)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  puts "#{swings.size} confirmed swings (#{swings.map(&:type).tally})"

  extractor = ContextFeatureExtractor.new(profile)
  labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target)

  baseline_samples = labeler.label_baseline_samples(
    candles: candles, regimes: regimes, funding_series: funding_series,
    feature_extractor: extractor, forward_horizon_bars: 20, stride: 5
  )
  puts "#{baseline_samples.size} baseline samples"

  bar_interval_minutes = candles.size >= 2 ? ((candles[1][:ts] - candles[0][:ts]) / 60.0).round : 15
  cost_model = TradeCostModel.new(
    fee_bps_per_side: FEE_BPS_PER_SIDE,
    slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE,
    bar_interval_minutes: bar_interval_minutes
  )

  [1, 3].each do |delay|
    events = labeler.label_signal_events(
      candles: candles, swings: swings, regimes: regimes, funding_series: funding_series,
      feature_extractor: extractor, entry_delay_bars: delay, forward_horizon_bars: 20
    )
    buckets = SignatureAnalyzer.analyze(swing_events: events, baseline_samples: baseline_samples)
    print_bucket_table("delay_#{delay}_bars (n=#{events.size} signal events)", buckets)

    buckets.each do |b|
      plan = DynamicRiskPlanner.plan(bucket_stats: b)
      next unless plan.tradeable

      puts "  TRADEABLE: #{b.bucket_key} delay=#{delay} -> r_target=#{plan.r_multiple_target} " \
           "risk_pct=#{plan.risk_pct} (#{plan.reason})"
    end
  
    oos_result = WalkForwardDiscoveryEvaluator.new(
      profile: profile,
      cost_model: cost_model,
      entry_delay_bars: delay
    ).evaluate(
      candles: candles,
      funding_series: funding_series,
      n_folds: WALK_FORWARD_FOLDS,
      embargo_bars: EMBARGO_BARS
    )
    print_walk_forward_summary("walk_forward_oos delay=#{delay}", oos_result)
  end
end

puts "\n#{'=' * 70}"
puts "Done. Raw data cached under #{CACHE_DIR} — delete files or set FORCE_REFRESH=1 to re-pull."

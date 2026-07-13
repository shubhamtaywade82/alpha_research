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

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
INTERVAL = "15m"
DAYS_BACK = 90
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
  end
end

puts "\n#{'=' * 70}"
puts "Done. Raw data cached under #{CACHE_DIR} — delete files or set FORCE_REFRESH=1 to re-pull."
puts "Reminder: this is ONE historical window, not yet walk-forward validated."
puts "Next step before trusting any TRADEABLE bucket above: run it through"
puts "WalkForwardValidator with purge/embargo across multiple folds."

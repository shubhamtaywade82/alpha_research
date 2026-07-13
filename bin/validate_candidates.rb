#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 2: Read the experiment DB, pick top contenders by trending_bear edge,
# run walk-forward validation on each, and update results.

require "fileutils"
require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/experiment_store"
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/swing_point_detector"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/move_labeler"
require_relative "../lib/signature_analyzer"
require_relative "../lib/walk_forward_validator"

EXPERIMENT_PATH = File.join(root, "data", "experiments.jsonl")

unless File.exist?(EXPERIMENT_PATH)
  puts "No experiment database found at #{EXPERIMENT_PATH}"
  puts "Run `ruby bin/sweep_parameters.rb` first."
  exit 1
end

store = ExperimentStore.new(EXPERIMENT_PATH)
existing_wf = store.query(phase: "walk_forward")
already_validated = existing_wf.map { |e| [e["symbol"], e["parameters"]["stop_atr_buffer"], e["parameters"]["forward_horizon_bars"], e["parameters"]["entry_delay_bars"]] }

# Rank single-window experiments by trending_bear edge
candidates = store.query(phase: "single_window")
  .reject { |e| already_validated.include?([e["symbol"], e["parameters"]["stop_atr_buffer"], e["parameters"]["forward_horizon_bars"], e["parameters"]["entry_delay_bars"]]) }
  .sort_by { |e| -(e.dig("single_window", "regimes", "trending_bear", "edge") || -999) }
  .first(15)

if candidates.empty?
  puts "No candidates to validate."
  puts "Already validated: #{existing_wf.size}" if existing_wf.any?
  puts "Run `ruby bin/sweep_parameters.rb` first if you need to generate candidates."
  exit 0
end

# Group by symbol and load data once per symbol
symbols_needed = candidates.map { |c| c["symbol"] }.uniq
loaded = {}

symbols_needed.each do |symbol|
  profile = SymbolProfile.for(symbol)
  cache_dir = File.join(root, "data", "cache")

  raw_klines = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_klines_15m_90d.json")))
  raw_funding = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_funding_90d.json")))

  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  regimes = RegimeClassifier.new(profile).classify(candles)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  extractor = ContextFeatureExtractor.new(profile)

  loaded[symbol] = {
    profile: profile, candles: candles, funding_series: funding_series,
    regimes: regimes, swings: swings, extractor: extractor
  }
end

puts "Validating #{candidates.size} candidates across #{symbols_needed.size} symbols..."
puts

candidates.each do |exp|
  symbol = exp["symbol"]
  p = exp["parameters"]
  data = loaded[symbol]
  bear_edge = exp.dig("single_window", "regimes", "trending_bear", "edge")&.round(3) || 0
  next if bear_edge <= 0

  labeler = MoveLabeler.new(atr_period: 14, stop_atr_buffer: p["stop_atr_buffer"],
                            r_multiple_target: p["r_multiple_target"])

  wf_result = WalkForwardValidator.run(candles: data[:candles], n_folds: 5, embargo_bars: 100) do |fold|
    test_end = fold.test_range.last
    fe = labeler.label_signal_events(
      candles: data[:candles][0..test_end], swings: data[:swings].select { |s| s.index <= test_end },
      regimes: data[:regimes][0..test_end], funding_series: data[:funding_series][0..test_end],
      feature_extractor: data[:extractor], entry_delay_bars: p["entry_delay_bars"],
      forward_horizon_bars: p["forward_horizon_bars"])
    fe.select { |e| fold.test_range.include?(e.entry_index) }.map { |e| { r_multiple: e.r_multiple } }
  end

  store.record(
    symbol: symbol,
    parameters: p,
    single_window_bear_edge: bear_edge,
    walk_forward: wf_result,
    phase: "walk_forward"
  )

  agg = wf_result[:aggregate]
  puts format("%-9s stop=%.1f h=%d d=%d  bear_edge=%+.3f -> wf_exp=%+.3f wr=%.3f dd=%.1f folds=%d/%d",
               symbol, p["stop_atr_buffer"], p["forward_horizon_bars"],
               p["entry_delay_bars"], bear_edge,
               agg[:mean_expectancy_r] || 0, agg[:mean_win_rate] || 0,
               agg[:worst_fold_drawdown_r] || 0, agg[:folds_with_trades] || 0, agg[:total_folds] || 0)
end

# Final leaderboard
puts "\n#{'=' * 70}"
puts "Walk-validated leaderboard (mean_expectancy_r)"
puts "=" * 70
wf_all = store.query(phase: "walk_forward")
  .sort_by { |e| -(e.dig("walk_forward", "aggregate", "mean_expectancy_r") || -999) }

if wf_all.any?
  puts format("%-9s %5s %4s %4s %8s %6s %6s %8s", "Symbol", "Stop", "Horz", "Del", "Exp", "WR", "DD", "BearEdge")
  wf_all.each do |e|
    wf = e["walk_forward"] or next
    a = wf["aggregate"] or next
    puts format("%-9s %5.1f %4d %4d %+8.3f %6.3f %6.1f %+8.3f",
                 e["symbol"], e["parameters"]["stop_atr_buffer"],
                 e["parameters"]["forward_horizon_bars"], e["parameters"]["entry_delay_bars"],
                 a["mean_expectancy_r"], a["mean_win_rate"],
                 a["worst_fold_drawdown_r"], e["single_window_bear_edge"])
  end
end

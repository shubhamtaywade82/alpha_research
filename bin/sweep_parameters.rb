#!/usr/bin/env ruby
# frozen_string_literal: true

# Two-phase sweep:
#   1. Single-window analysis for ALL parameter combos (fast, casts wide net)
#   2. Walk-forward validation on top combos (expensive, but few candidates)

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
require_relative "../lib/dynamic_risk_planner"
require_relative "../lib/walk_forward_validator"

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
INTERVAL = "15m"
DAYS_BACK = 90

CACHE_DIR = File.join(root, "data", "cache")
EXPERIMENT_PATH = File.join(root, "data", "experiments.jsonl")
FileUtils.mkdir_p(CACHE_DIR)

STOP_BUFFERS = [0.3, 0.5, 0.7, 1.0].freeze
HORIZONS = [10, 20, 40].freeze
DELAYS = [1, 3].freeze

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

store = ExperimentStore.new(EXPERIMENT_PATH)

# ── Phase 1: single-window sweep ──────────────────────────────────
puts "Phase 1: Single-window sweep across all combos"

top_candidates = []

SYMBOLS.each do |symbol|
  puts "\n#{'=' * 70}"
  puts "#{symbol}"
  puts "=" * 70

  profile = SymbolProfile.for(symbol)

  raw_klines = cached_fetch("#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d") do
    BinanceDataLoader.fetch_klines(symbol: symbol, interval: INTERVAL, days_back: DAYS_BACK)
  end
  raw_funding = cached_fetch("#{symbol}_funding_#{DAYS_BACK}d") do
    BinanceDataLoader.fetch_funding_rate_history(symbol: symbol, days_back: DAYS_BACK)
  end

  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)

  regimes = RegimeClassifier.new(profile).classify(candles)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  extractor = ContextFeatureExtractor.new(profile)

  total = STOP_BUFFERS.size * HORIZONS.size * DELAYS.size
  idx = 0

  STOP_BUFFERS.each do |stop_buffer|
    HORIZONS.each do |horizon|
      DELAYS.each do |delay|
        idx += 1
        labeler = MoveLabeler.new(
          atr_period: 14, stop_atr_buffer: stop_buffer,
          r_multiple_target: profile.r_multiple_target
        )

        events = labeler.label_signal_events(
          candles: candles, swings: swings, regimes: regimes,
          funding_series: funding_series, feature_extractor: extractor,
          entry_delay_bars: delay, forward_horizon_bars: horizon
        )

        baseline = labeler.label_baseline_samples(
          candles: candles, regimes: regimes, funding_series: funding_series,
          feature_extractor: extractor, forward_horizon_bars: horizon, stride: 5
        )

        buckets = SignatureAnalyzer.analyze(swing_events: events, baseline_samples: baseline)
        regime_buckets = buckets.each_with_object({}) do |b, h|
          h[b.bucket_key.to_s] = {
            n: b.swing_count, mean_r: b.swing_mean_r, win_rate: b.swing_win_rate,
            edge: b.edge_over_baseline
          }
        end

        store.record(
          symbol: symbol,
          parameters: {
            stop_atr_buffer: stop_buffer, forward_horizon_bars: horizon,
            entry_delay_bars: delay, r_multiple_target: profile.r_multiple_target
          },
          single_window: { total_events: events.size, regimes: regime_buckets },
          phase: "single_window"
        )

        bear_edge = regime_buckets.dig("trending_bear", :edge)&.round(3) || 0
        totals = regime_buckets.values.sum { |b| b[:n] || 0 }
        win_rate_all = totals.positive? ?
          regime_buckets.values.sum { |b| (b[:n] || 0) * (b[:win_rate] || 0) } / totals.to_f : 0

        printf "  [%2d/%d] stop=%.1f h=%d d=%d  wr=%.3f bear_edge=%+.3f mean_r=%.3f\n",
               idx, total, stop_buffer, horizon, delay,
               win_rate_all, bear_edge,
               regime_buckets.values.sum { |b| (b[:n] || 0) * (b[:mean_r] || 0) } / (totals > 0 ? totals : 1)

        top_candidates << {
          symbol: symbol, stop_buffer: stop_buffer, horizon: horizon,
          delay: delay, bear_edge: bear_edge,
          profile: profile, candles: candles, funding_series: funding_series,
          regimes: regimes, swings: swings, extractor: extractor
        }
      end
    end
  end
end

# ── Phase 2: Walk-forward on top 3 per symbol ─────────────────────
puts "\n#{'=' * 70}"
puts "Phase 2: Walk-forward validation on top candidates"
puts "=" * 70

best_per_symbol = top_candidates
  .group_by { |c| c[:symbol] }
  .transform_values { |cs| cs.sort_by { |c| -(c[:bear_edge] || -999) }.first(3) }

best_per_symbol.each do |symbol, candidates|
  puts "\n#{symbol}:"
  candidates.each do |c|
    next if c[:bear_edge] <= 0

    labeler = MoveLabeler.new(
      atr_period: 14, stop_atr_buffer: c[:stop_buffer],
      r_multiple_target: c[:profile].r_multiple_target
    )

    wf_result = WalkForwardValidator.run(candles: c[:candles], n_folds: 5, embargo_bars: 100) do |fold|
      test_end = fold.test_range.last
      fold_candles = c[:candles][0..test_end]
      fold_funding = c[:funding_series][0..test_end]
      fold_regimes = c[:regimes][0..test_end]
      fold_swings = c[:swings].select { |s| s.index <= test_end }

      fe = labeler.label_signal_events(
        candles: fold_candles, swings: fold_swings, regimes: fold_regimes,
        funding_series: fold_funding, feature_extractor: c[:extractor],
        entry_delay_bars: c[:delay], forward_horizon_bars: c[:horizon]
      )
      fe.select { |e| fold.test_range.include?(e.entry_index) }.map { |e| { r_multiple: e.r_multiple } }
    end

    store.record(
      symbol: symbol,
      parameters: {
        stop_atr_buffer: c[:stop_buffer], forward_horizon_bars: c[:horizon],
        entry_delay_bars: c[:delay], r_multiple_target: c[:profile].r_multiple_target
      },
      single_window_bear_edge: c[:bear_edge],
      walk_forward: wf_result,
      phase: "walk_forward"
    )

    agg = wf_result[:aggregate]
    puts format("  stop=%.1f h=%d d=%d  bear_edge=%+.3f -> wf_exp=%+.3f wr=%.3f dd=%.1f folds=%d/%d",
                 c[:stop_buffer], c[:horizon], c[:delay], c[:bear_edge],
                 agg[:mean_expectancy_r] || 0, agg[:mean_win_rate] || 0,
                 agg[:worst_fold_drawdown_r] || 0, agg[:folds_with_trades] || 0, agg[:total_folds] || 0)
  end
end

# ── Final leaderboard ──────────────────────────────────────────────
puts "\n#{'=' * 70}"
puts "Final leaderboard (walk-forward mean_expectancy_r)"
puts "=" * 70

wf_experiments = store.query(phase: "walk_forward")
  .sort_by { |e| -(e.dig("walk_forward", "aggregate", "mean_expectancy_r") || -999) }

if wf_experiments.empty?
  puts "No walk-forward experiments recorded (all bear_edges were <= 0)."
else
  puts format("%-9s %5s %4s %4s %8s %6s %6s %8s", "Symbol", "Stop", "Horz", "Del", "Exp", "WR", "DD", "BearEdge")
  wf_experiments.each do |e|
    p = e["parameters"]
    a = e["walk_forward"]["aggregate"]
    puts format("%-9s %5.1f %4d %4d %+8.3f %6.3f %6.1f %+8.3f",
                 e["symbol"], p["stop_atr_buffer"], p["forward_horizon_bars"],
                 p["entry_delay_bars"], a["mean_expectancy_r"], a["mean_win_rate"],
                 a["worst_fold_drawdown_r"], e["single_window_bear_edge"])
  end
end

puts "\nTotal experiments: #{store.count} (#{EXPERIMENT_PATH})"

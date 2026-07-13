#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 1: Calibrate SymbolProfile params (adx threshold, EMA pair, R target)
# plus signal params (stop buffer, horizon, delay) via a single-window grid
# over the research slice (first 80% of each series — never the holdout).
# Records every combo to the experiment DB, then writes the winning profile
# knobs per symbol to data/calibrated_profiles.json.
#
# Usage:
#   ruby bin/sweep_parameters.rb
#
# Then validate the best candidates:
#   ruby bin/validate_candidates.rb

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
require_relative "../lib/data_window"

SYMBOLS = (ENV["SYMBOL"] ? [ENV["SYMBOL"]] : %w[SOLUSDT ETHUSDT XRPUSDT]).freeze
CACHE_DIR = File.join(root, "data", "cache")
EXPERIMENT_PATH = File.join(root, "data", "experiments.jsonl")
CALIBRATED_PATH = File.join(root, "data", "calibrated_profiles.json")
FileUtils.mkdir_p(CACHE_DIR)

# (interval, cache klines key) — funding_365d covers both windows (funding
# events are timestamp-based, independent of candle interval).
DATASETS = {
  "15m" => "klines_15m_180d",
  "1h" => "klines_1h_365d"
}.freeze

ADX_THRESHOLDS = [18.0, 22.0, 26.0].freeze
EMA_PAIRS = [[13, 34], [21, 55], [34, 89]].freeze
R_TARGETS = [1.5, 2.0, 3.0].freeze
STOP_BUFFERS = [0.7, 1.0, 1.5].freeze
HORIZONS = [10, 20, 40].freeze
DELAYS = [1, 3].freeze

def load_candles(symbol, interval, klines_key)
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_#{klines_key}.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_365d.json")))
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  [DataWindow.research_slice(candles), DataWindow.research_slice(funding_series)]
end

def weighted_edge(buckets)
  scored = buckets.select { |b| b[:n] && b[:n] >= 30 && b[:edge] }
  return nil if scored.empty?

  total_n = scored.sum { |b| b[:n] }
  scored.sum { |b| b[:edge] * b[:n] } / total_n.to_f
end

store = ExperimentStore.new(EXPERIMENT_PATH)
total_combos = ADX_THRESHOLDS.size * EMA_PAIRS.size * R_TARGETS.size * STOP_BUFFERS.size * HORIZONS.size * DELAYS.size
puts "Calibration grid: #{ADX_THRESHOLDS.size} adx x #{EMA_PAIRS.size} ema x #{R_TARGETS.size} r_target x " \
     "#{STOP_BUFFERS.size} stop x #{HORIZONS.size} horizon x #{DELAYS.size} delay = #{total_combos} combos/symbol/TF\n\n"

best_per_symbol = Hash.new { |h, k| h[k] = { score: -Float::INFINITY } }

SYMBOLS.each do |symbol|
  base_profile = SymbolProfile.for(symbol)

  DATASETS.each do |tf_label, klines_key|
    puts "── #{symbol} #{tf_label} ──────────────────────────────────────"
    candles, funding_series = load_candles(symbol, tf_label, klines_key)

    idx = 0
    ADX_THRESHOLDS.each do |adx_thr|
      EMA_PAIRS.each do |ema_fast, ema_slow|
        profile = base_profile.dup
        profile.adx_trend_threshold = adx_thr
        profile.ema_fast = ema_fast
        profile.ema_slow = ema_slow

        regimes = RegimeClassifier.new(profile).classify(candles)
        swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
        extractor = ContextFeatureExtractor.new(profile)
        closes = candles.map { |c| c[:close] }
        extractor.ema_cache_fast = Indicators.ema(closes, ema_fast)
        extractor.ema_cache_slow = Indicators.ema(closes, ema_slow)
        atr_series = Indicators.atr(candles, 14)

        R_TARGETS.each do |r_target|
          STOP_BUFFERS.each do |stop_buffer|
            HORIZONS.each do |horizon|
              DELAYS.each do |delay|
                idx += 1
                labeler = MoveLabeler.new(atr_period: 14, stop_atr_buffer: stop_buffer,
                                          r_multiple_target: r_target, atr_cache: atr_series)

                events = labeler.label_signal_events(
                  candles: candles, swings: swings, regimes: regimes,
                  funding_series: funding_series, feature_extractor: extractor,
                  entry_delay_bars: delay, forward_horizon_bars: horizon)

                baseline = labeler.label_baseline_samples(
                  candles: candles, regimes: regimes, funding_series: funding_series,
                  feature_extractor: extractor, forward_horizon_bars: horizon, stride: 5)

                buckets = SignatureAnalyzer.analyze(swing_events: events, baseline_samples: baseline)
                r = buckets.each_with_object({}) { |b, h| h[b.bucket_key.to_s] = {
                  n: b.swing_count, mean_r: b.swing_mean_r, win_rate: b.swing_win_rate, edge: b.edge_over_baseline } }

                score = weighted_edge(r.values)

                store.record(
                  symbol: symbol,
                  timeframe: tf_label,
                  parameters: { adx_trend_threshold: adx_thr, ema_fast: ema_fast, ema_slow: ema_slow,
                                r_multiple_target: r_target, stop_atr_buffer: stop_buffer,
                                forward_horizon_bars: horizon, entry_delay_bars: delay },
                  single_window: { total_events: events.size, regimes: r, weighted_edge: score },
                  phase: "profile_sweep")

                if score && score > best_per_symbol[symbol][:score]
                  best_per_symbol[symbol] = {
                    score: score, timeframe: tf_label,
                    adx_trend_threshold: adx_thr, ema_fast: ema_fast, ema_slow: ema_slow,
                    r_multiple_target: r_target, stop_atr_buffer: stop_buffer,
                    forward_horizon_bars: horizon, entry_delay_bars: delay,
                    total_events: events.size
                  }
                end
              end
            end
          end
        end
        printf "  adx=%.0f ema=%d/%d done (%d/%d combos so far)\n", adx_thr, ema_fast, ema_slow, idx, total_combos
      end
    end
  end
end

new_entries = best_per_symbol.each_with_object({}) do |(symbol, best), h|
  h[symbol] = {
    "adx_trend_threshold" => best[:adx_trend_threshold],
    "ema_fast" => best[:ema_fast],
    "ema_slow" => best[:ema_slow],
    "r_multiple_target" => best[:r_multiple_target],
    "calibration_timeframe" => best[:timeframe],
    "calibration_weighted_edge" => best[:score]&.round(3),
    "calibration_total_events" => best[:total_events]
  }
end
# Merge rather than overwrite — allows running one process per symbol
# (SYMBOL=SOLUSDT ruby bin/sweep_parameters.rb &, etc.) without clobbering
# other symbols' already-written calibration.
# ponytail: read-merge-write race if two symbol processes finish in the same
# instant; fine here since finish times differ by minutes. Add a file lock
# if this script starts running with true concurrent finishes.
existing = File.exist?(CALIBRATED_PATH) ? JSON.parse(File.read(CALIBRATED_PATH)) : {}
calibrated = existing.merge(new_entries)
File.write(CALIBRATED_PATH, JSON.pretty_generate(calibrated))

puts "\nDone — #{store.count} experiments in #{EXPERIMENT_PATH}"
puts "Calibrated profiles written to #{CALIBRATED_PATH}:"
puts JSON.pretty_generate(calibrated)
puts "\nRun `ruby bin/validate_candidates.rb` to walk-forward validate the best combos."

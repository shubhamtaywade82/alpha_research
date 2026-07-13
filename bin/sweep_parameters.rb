#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 1: Single-window sweep across all parameter combos.
# Fast — no per-fold recomputation. Records every combo in the experiment DB.
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

puts "Sweeping #{STOP_BUFFERS.size} stops × #{HORIZONS.size} horizons × #{DELAYS.size} delays = #{STOP_BUFFERS.size * HORIZONS.size * DELAYS.size} combos per symbol\n\n"

SYMBOLS.each do |symbol|
  puts "── #{symbol} ──────────────────────────────────────"

  profile = SymbolProfile.for(symbol)
  raw_klines = cached_fetch("#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d") {
    BinanceDataLoader.fetch_klines(symbol: symbol, interval: INTERVAL, days_back: DAYS_BACK)
  }
  raw_funding = cached_fetch("#{symbol}_funding_#{DAYS_BACK}d") {
    BinanceDataLoader.fetch_funding_rate_history(symbol: symbol, days_back: DAYS_BACK)
  }

  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)

  regimes = RegimeClassifier.new(profile).classify(candles)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  extractor = ContextFeatureExtractor.new(profile)

  # Precompute once — avoids O(n²) per combo from EMA/ATR recomputation
  closes = candles.map { |c| c[:close] }
  extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
  extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)
  atr_series = Indicators.atr(candles, 14)

  total = STOP_BUFFERS.size * HORIZONS.size * DELAYS.size
  idx = 0

  STOP_BUFFERS.each do |stop_buffer|
    HORIZONS.each do |horizon|
      DELAYS.each do |delay|
        idx += 1
        labeler = MoveLabeler.new(atr_period: 14, stop_atr_buffer: stop_buffer,
                                  r_multiple_target: profile.r_multiple_target,
                                  atr_cache: atr_series)

        events = labeler.label_signal_events(
          candles: candles, swings: swings, regimes: regimes,
          funding_series: funding_series,
          feature_extractor: extractor,
          entry_delay_bars: delay, forward_horizon_bars: horizon)

        baseline = labeler.label_baseline_samples(
          candles: candles, regimes: regimes, funding_series: funding_series,
          feature_extractor: extractor, forward_horizon_bars: horizon, stride: 5)

        buckets = SignatureAnalyzer.analyze(swing_events: events, baseline_samples: baseline)
        r = buckets.each_with_object({}) { |b, h| h[b.bucket_key.to_s] = {
          n: b.swing_count, mean_r: b.swing_mean_r, win_rate: b.swing_win_rate, edge: b.edge_over_baseline } }

        store.record(
          symbol: symbol,
          parameters: { stop_atr_buffer: stop_buffer, forward_horizon_bars: horizon,
                        entry_delay_bars: delay, r_multiple_target: profile.r_multiple_target },
          single_window: { total_events: events.size, regimes: r },
          phase: "single_window")

        be = r.dig("trending_bear", :edge)&.round(3) || 0
        printf "  [%2d/%d] stop=%.1f h=%d d=%d  wr=%.3f bear_edge=%+.3f\n", idx, total,
               stop_buffer, horizon, delay, r.values.sum { |b| (b[:n] || 0) * (b[:win_rate] || 0) } / [r.values.sum { |b| b[:n] || 0 }, 1].max.to_f, be
      end
    end
  end
end

puts "\nDone — #{store.count} experiments in #{EXPERIMENT_PATH}"
puts "Run `ruby bin/validate_candidates.rb` to walk-forward validate the best combos."

#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 2 (discovery family): walk-forward OOS grid across 5 LTF-entry /
# HTF-regime timeframe pairs x stop/r_target/horizon/delay params, using
# the Phase-1 calibrated SymbolProfile. Regimes/swings/ATR are precomputed
# once per symbol/TF-pair (they don't depend on the inner grid), so the 54
# inner combos only re-run labeling, not indicator/regime recomputation.
# Records every combo to the experiment DB for bin/validate_candidates.rb.
#
# Usage:
#   ruby bin/run_multitimeframe_research.rb

require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/experiment_store"
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/trade_cost_model"
require_relative "../lib/walk_forward_discovery_evaluator"
require_relative "../lib/candle_resampler"
require_relative "../lib/swing_point_detector"
require_relative "../lib/indicators"
require_relative "../lib/data_window"
require_relative "../lib/context_feature_extractor"

SYMBOLS = (ENV["SYMBOL"] ? [ENV["SYMBOL"]] : %w[SOLUSDT ETHUSDT XRPUSDT]).freeze
CACHE_DIR = File.join(root, "data", "cache")
EXPERIMENT_PATH = File.join(root, "data", "experiments.jsonl")

FEE_BPS_PER_SIDE = 4.0
SLIPPAGE_BPS_PER_SIDE = 2.0

# All TF pairs resample from one of the two base series fetched in Phase 0.
# factor is relative to that base series' own interval.
TF_PAIRS = [
  { label: "15m+1h", base: "15m_180d", base_minutes: 15, entry_factor: 1, htf_factor: 4, n_folds: 6, htf_label: "1h" },
  { label: "15m+4h", base: "15m_180d", base_minutes: 15, entry_factor: 1, htf_factor: 16, n_folds: 6, htf_label: "4h" },
  { label: "1h+4h", base: "1h_365d", base_minutes: 60, entry_factor: 1, htf_factor: 4, n_folds: 8, htf_label: "4h" },
  { label: "2h+4h", base: "1h_365d", base_minutes: 60, entry_factor: 2, htf_factor: 4, n_folds: 8, htf_label: "4h" },
  { label: "4h+1d", base: "1h_365d", base_minutes: 60, entry_factor: 4, htf_factor: 24, n_folds: 8, htf_label: "1d" }
].freeze

STOP_BUFFERS = [0.7, 1.0, 1.5].freeze
R_TARGETS = [1.5, 2.0, 3.0].freeze
HORIZONS = [10, 20, 40].freeze
DELAYS = [1, 3].freeze

def load_base(symbol, base_key)
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_klines_#{base_key}.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_365d.json")))
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  [DataWindow.research_slice(candles), DataWindow.research_slice(funding_series)]
end

store = ExperimentStore.new(EXPERIMENT_PATH)
total_per_pair = STOP_BUFFERS.size * R_TARGETS.size * HORIZONS.size * DELAYS.size
puts "MTF grid: #{TF_PAIRS.size} TF pairs x #{total_per_pair} param combos = #{TF_PAIRS.size * total_per_pair} runs/symbol\n\n"

SYMBOLS.each do |symbol|
  profile = SymbolProfile.for(symbol)
  base_cache = {}

  TF_PAIRS.each do |pair|
    puts "── #{symbol} #{pair[:label]} ──────────────────────────────────────"

    base_candles, base_funding = (base_cache[pair[:base]] ||= load_base(symbol, pair[:base]))
    entry_candles = CandleResampler.resample_candles(base_candles, pair[:entry_factor])
    entry_funding = CandleResampler.resample_series(base_funding, pair[:entry_factor])
    htf_candles = CandleResampler.resample_candles(base_candles, pair[:htf_factor])
    if entry_candles.size < 400 || htf_candles.size < 100
      puts "  skipped: insufficient candles (entry=#{entry_candles.size}, htf=#{htf_candles.size})"
      next
    end

    htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
    aligned_htf_regimes = CandleResampler.align_higher_regimes(
      lower_candles: entry_candles, higher_candles: htf_candles, higher_regimes: htf_regimes
    )
    entry_regimes = RegimeClassifier.new(profile).classify(entry_candles)
    swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(entry_candles)
    atr_cache = Indicators.atr(entry_candles, 14)
    closes = entry_candles.map { |c| c[:close] }
    extractor = ContextFeatureExtractor.new(profile)
    extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
    extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)

    entry_minutes = pair[:base_minutes] * pair[:entry_factor]
    cost_model = TradeCostModel.new(fee_bps_per_side: FEE_BPS_PER_SIDE, slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE,
                                     bar_interval_minutes: entry_minutes)

    idx = 0
    STOP_BUFFERS.each do |stop_buffer|
      R_TARGETS.each do |r_target|
        HORIZONS.each do |horizon|
          DELAYS.each do |delay|
            idx += 1
            embargo_bars = horizon + profile.structure_lookback

            profile_for_run = profile.dup
            profile_for_run.r_multiple_target = r_target

            result = WalkForwardDiscoveryEvaluator.new(
              profile: profile_for_run,
              cost_model: cost_model,
              entry_delay_bars: delay,
              forward_horizon_bars: horizon,
              stop_atr_buffer: stop_buffer,
              htf_regimes: aligned_htf_regimes,
              bucket_by: lambda { |ctx|
                htf = ctx.key?(:htf_aligned) ? ctx[:htf_aligned] : :unknown
                "#{ctx[:regime_state]}|#{pair[:htf_label]}_aligned=#{htf}"
              },
              regimes: entry_regimes, swings: swings, atr_cache: atr_cache, extractor: extractor
            ).evaluate(
              candles: entry_candles, funding_series: entry_funding,
              n_folds: pair[:n_folds], embargo_bars: embargo_bars
            )

            store.record(
              symbol: symbol,
              family: "discovery",
              timeframe_pair: pair[:label],
              parameters: { stop_atr_buffer: stop_buffer, r_multiple_target: r_target,
                            forward_horizon_bars: horizon, entry_delay_bars: delay },
              walk_forward: result,
              phase: "mtf_walk_forward"
            )

            agg = result[:aggregate]
            next if agg[:note]

            printf "  [%2d/%d] stop=%.1f r=%.1f h=%d d=%d  trades=%-4d net_r=%-7s alpha=%-7s sharpe=%-6s\n",
                   idx, total_per_pair, stop_buffer, r_target, horizon, delay,
                   agg[:total_trades], agg[:mean_net_expectancy_r].inspect, agg[:mean_alpha_net_r].inspect,
                   agg[:mean_sharpe].inspect
          end
        end
      end
    end
  end
end

puts "\nDone — #{store.count} experiments in #{EXPERIMENT_PATH}"

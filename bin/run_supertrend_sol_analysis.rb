#!/usr/bin/env ruby
# frozen_string_literal: true

# Deep-dive: adaptive SuperTrend variants for SOLUSDT only, wider indicator
# param grid than the main 3-symbol sweep, PLUS two explicit gating
# dimensions layered on top of the existing regime-bucket discovery:
#
#   trending_only: drop every flip event whose OWN bar isn't already in a
#     trending_bull/trending_bear regime (a hard pre-filter, vs. the normal
#     pipeline which lets bucket-discovery implicitly pick whichever regime
#     bucket clears the edge bar — this asks "does forcing trend-only entries
#     help, or does the discovery step already find the right bucket anyway?")
#   require_htf_alignment: drop every flip event whose bar's HTF regime
#     doesn't match its own regime (hard pre-filter, same idea as the
#     confluence family's optional HTF gate, applied here to supertrend).
#
# Records to the SAME experiments.jsonl under phase: "mtf_walk_forward",
# family: "supertrend_percentile"/"supertrend_kmeans"/"supertrend_adaptive"
# (same as the main sweep) so bin/validate_candidates.rb ranks these
# together with everything else — parameters carry a "gate" field so
# gated vs ungated runs are distinguishable in the leaderboard.
#
# Usage:
#   ruby bin/run_supertrend_sol_analysis.rb

require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/experiment_store"
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/trade_cost_model"
require_relative "../lib/walk_forward_discovery_evaluator"
require_relative "../lib/candle_resampler"
require_relative "../lib/indicators"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/data_window"
require_relative "../lib/supertrend_calculator"
require_relative "../lib/supertrend_flip_detector"

SYMBOL = "SOLUSDT"
CACHE_DIR = File.join(root, "data", "cache")
EXPERIMENT_PATH = File.join(root, "data", "experiments.jsonl")

FEE_BPS_PER_SIDE = 4.0
SLIPPAGE_BPS_PER_SIDE = 2.0

TF_PAIRS = [
  { label: "15m+1h", base: "15m_180d", base_minutes: 15, entry_factor: 1, htf_factor: 4, n_folds: 6, htf_label: "1h" },
  { label: "15m+4h", base: "15m_180d", base_minutes: 15, entry_factor: 1, htf_factor: 16, n_folds: 6, htf_label: "4h" },
  { label: "1h+4h", base: "1h_365d", base_minutes: 60, entry_factor: 1, htf_factor: 4, n_folds: 8, htf_label: "4h" },
  { label: "2h+4h", base: "1h_365d", base_minutes: 60, entry_factor: 2, htf_factor: 4, n_folds: 8, htf_label: "4h" },
  { label: "4h+1d", base: "1h_365d", base_minutes: 60, entry_factor: 4, htf_factor: 24, n_folds: 8, htf_label: "1d" }
].freeze

# Wider than the main 3-symbol sweep's 4-combo grid — this is the deep dive.
VARIANTS = {
  "supertrend_percentile" => {
    grid: [10, 14].product([1.0, 1.5], [2.5, 3.0, 4.0]).map { |atr_period, min_mult, max_mult|
      { atr_period: atr_period, min_mult: min_mult, max_mult: max_mult }
    },
    build: ->(candles, p) { SupertrendCalculator.percentile_scaled(candles, atr_period: p[:atr_period], min_mult: p[:min_mult], max_mult: p[:max_mult], pct_lookback: 100) }
  },
  "supertrend_kmeans" => {
    grid: [10, 14].product([0.75, 1.0], [1.5, 2.0], [3.0, 4.0]).map { |atr_period, mult_low, mult_mid, mult_high|
      { atr_period: atr_period, mult_low: mult_low, mult_mid: mult_mid, mult_high: mult_high }
    },
    build: ->(candles, p) { SupertrendCalculator.kmeans_clustered(candles, atr_period: p[:atr_period], cluster_lookback: 100, mult_low: p[:mult_low], mult_mid: p[:mult_mid], mult_high: p[:mult_high]) }
  },
  "supertrend_adaptive" => {
    grid: [10, 14].product([1.0, 1.5], [2.5, 3.0, 4.0]).map { |base_period, min_mult, max_mult|
      { base_period: base_period, min_period: 7, max_period: 21, min_mult: min_mult, max_mult: max_mult, er_lookback: 10 }
    },
    build: ->(candles, p) { SupertrendCalculator.fully_adaptive(candles, base_period: p[:base_period], min_period: p[:min_period], max_period: p[:max_period], min_mult: p[:min_mult], max_mult: p[:max_mult], er_lookback: p[:er_lookback], pct_lookback: 100) }
  }
}.freeze

GATE_COMBOS = [
  { trending_only: false, require_htf_alignment: false, label: "ungated" },
  { trending_only: true, require_htf_alignment: false, label: "trending_only" },
  { trending_only: false, require_htf_alignment: true, label: "htf_aligned" },
  { trending_only: true, require_htf_alignment: true, label: "trending+htf" }
].freeze

TRADE_GRID = [1.0].product([2.0, 3.0], [20], [1, 3]).map { |stop, r, horizon, delay|
  { stop_atr_buffer: stop, r_multiple_target: r, forward_horizon_bars: horizon, entry_delay_bars: delay }
}.freeze

def load_base(cache_dir, symbol, base_key)
  raw_klines = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_klines_#{base_key}.json")))
  raw_funding = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_funding_365d.json")))
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  [DataWindow.research_slice(candles), DataWindow.research_slice(funding_series)]
end

# Applies the explicit gates as a hard pre-filter on flip events, BEFORE
# they ever reach bucket-discovery — distinct from the normal pipeline,
# where bucket-discovery implicitly selects whichever regime/htf bucket
# clears the edge bar.
def apply_gates(flips, entry_regimes, aligned_htf, gate)
  flips.select do |flip|
    idx = flip.confirmed_index
    regime = entry_regimes[idx]
    next false if regime.nil?

    if gate[:trending_only]
      next false unless [:trending_bull, :trending_bear].include?(regime.state)
    end

    if gate[:require_htf_alignment]
      htf = aligned_htf[idx]
      next false if htf.nil? || htf.state != regime.state
    end

    true
  end
end

store = ExperimentStore.new(EXPERIMENT_PATH)
total_per_pair = VARIANTS.values.sum { |v| v[:grid].size } * GATE_COMBOS.size * TRADE_GRID.size
puts "SOL SuperTrend deep dive: #{VARIANTS.values.sum { |v| v[:grid].size }} indicator combos x #{GATE_COMBOS.size} gates x #{TRADE_GRID.size} trade combos = #{total_per_pair} runs/TF-pair\n\n"

profile = SymbolProfile.for(SYMBOL)
base_cache = {}

TF_PAIRS.each do |pair|
  puts "── #{SYMBOL} #{pair[:label]} ──────────────────────────────────────"

  base_candles, base_funding = (base_cache[pair[:base]] ||= load_base(CACHE_DIR, SYMBOL, pair[:base]))
  entry_candles = CandleResampler.resample_candles(base_candles, pair[:entry_factor])
  entry_funding = CandleResampler.resample_series(base_funding, pair[:entry_factor])
  htf_candles = CandleResampler.resample_candles(base_candles, pair[:htf_factor])
  if entry_candles.size < 400 || htf_candles.size < 100
    puts "  skipped: insufficient candles"
    next
  end

  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_htf_regimes = CandleResampler.align_higher_regimes(lower_candles: entry_candles, higher_candles: htf_candles, higher_regimes: htf_regimes)
  entry_regimes = RegimeClassifier.new(profile).classify(entry_candles)
  atr_cache = Indicators.atr(entry_candles, 14)
  closes = entry_candles.map { |c| c[:close] }
  extractor = ContextFeatureExtractor.new(profile)
  extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
  extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)

  entry_minutes = pair[:base_minutes] * pair[:entry_factor]
  cost_model = TradeCostModel.new(fee_bps_per_side: FEE_BPS_PER_SIDE, slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE, bar_interval_minutes: entry_minutes)

  idx = 0
  VARIANTS.each do |family, variant|
    variant[:grid].each do |variant_params|
      supertrend_series = variant[:build].call(entry_candles, variant_params)
      raw_flips = SupertrendFlipDetector.detect(supertrend_series, entry_candles)

      GATE_COMBOS.each do |gate|
        flips = apply_gates(raw_flips, entry_regimes, aligned_htf_regimes, gate)

        TRADE_GRID.each do |trade_params|
          idx += 1
          if flips.size < 20
            next # not enough gated events to bother running the walk-forward evaluator
          end

          embargo_bars = trade_params[:forward_horizon_bars] + profile.structure_lookback
          profile_for_run = profile.dup
          profile_for_run.r_multiple_target = trade_params[:r_multiple_target]

          result = WalkForwardDiscoveryEvaluator.new(
            profile: profile_for_run, cost_model: cost_model, entry_delay_bars: trade_params[:entry_delay_bars],
            forward_horizon_bars: trade_params[:forward_horizon_bars], stop_atr_buffer: trade_params[:stop_atr_buffer],
            htf_regimes: aligned_htf_regimes,
            bucket_by: lambda { |ctx|
              htf = ctx.key?(:htf_aligned) ? ctx[:htf_aligned] : :unknown
              "#{ctx[:regime_state]}|#{pair[:htf_label]}_aligned=#{htf}"
            },
            regimes: entry_regimes, swings: flips, atr_cache: atr_cache, extractor: extractor
          ).evaluate(candles: entry_candles, funding_series: entry_funding, n_folds: pair[:n_folds], embargo_bars: embargo_bars)

          store.record(
            symbol: SYMBOL,
            family: family,
            timeframe_pair: pair[:label],
            parameters: variant_params.merge(trade_params).merge(gate: gate[:label]),
            walk_forward: result,
            phase: "mtf_walk_forward"
          )

          agg = result[:aggregate]
          next if agg[:note]

          printf "  [%4d/%d] %-22s gate=%-14s trades=%-4d net_r=%-7s alpha=%-7s\n",
                 idx, total_per_pair, family, gate[:label], agg[:total_trades], agg[:pooled_net_expectancy_r].inspect, agg[:pooled_alpha_net_r].inspect
        end
      end
    end
  end
end

puts "\nDone — #{store.count} experiments in #{EXPERIMENT_PATH}"

#!/usr/bin/env ruby
# frozen_string_literal: true

# Adaptive SuperTrend research: walk-forward OOS grid across 3 variants
# (percentile-scaled multiplier, k-means volatility-clustered multiplier,
# fully-adaptive period+multiplier), the same 5 TF pairs used for the
# discovery/confluence families, and a trade-risk grid (stop/target/horizon/
# delay). A SuperTrend flip is structurally a swing point (a directional
# pivot), so this reuses WalkForwardDiscoveryEvaluator/MoveLabeler/
# SignatureAnalyzer entirely unchanged via SupertrendFlipDetector — only the
# event source changes, not the evaluation machinery.
#
# Records to the SAME experiments.jsonl under phase: "mtf_walk_forward" with
# family: "supertrend_percentile" / "supertrend_kmeans" / "supertrend_adaptive"
# so bin/validate_candidates.rb ranks these against discovery/confluence with
# zero changes.
#
# Usage:
#   ruby bin/run_supertrend_research.rb
#   SYMBOL=SOLUSDT ruby bin/run_supertrend_research.rb   # one symbol, for parallel runs

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

SYMBOLS = (ENV["SYMBOL"] ? [ENV["SYMBOL"]] : %w[SOLUSDT ETHUSDT XRPUSDT]).freeze
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

VARIANTS = {
  "supertrend_percentile" => {
    grid: [10, 14].product([3.0, 4.0]).map { |atr_period, max_mult| { atr_period: atr_period, min_mult: 1.5, max_mult: max_mult } },
    build: ->(candles, p) { SupertrendCalculator.percentile_scaled(candles, atr_period: p[:atr_period], min_mult: p[:min_mult], max_mult: p[:max_mult], pct_lookback: 100) }
  },
  "supertrend_kmeans" => {
    grid: [10, 14].product([3.0, 4.0]).map { |atr_period, mult_high| { atr_period: atr_period, mult_low: 1.0, mult_mid: 2.0, mult_high: mult_high } },
    build: ->(candles, p) { SupertrendCalculator.kmeans_clustered(candles, atr_period: p[:atr_period], cluster_lookback: 100, mult_low: p[:mult_low], mult_mid: p[:mult_mid], mult_high: p[:mult_high]) }
  },
  "supertrend_adaptive" => {
    grid: [10, 14].product([3.0, 4.0]).map { |base_period, max_mult| { base_period: base_period, min_period: 7, max_period: 21, min_mult: 1.5, max_mult: max_mult, er_lookback: 10 } },
    build: ->(candles, p) { SupertrendCalculator.fully_adaptive(candles, base_period: p[:base_period], min_period: p[:min_period], max_period: p[:max_period], min_mult: p[:min_mult], max_mult: p[:max_mult], er_lookback: p[:er_lookback], pct_lookback: 100) }
  }
}.freeze

TRADE_GRID = [0.7, 1.0].product([2.0, 3.0], [20], [1, 3]).map { |stop, r, horizon, delay|
  { stop_atr_buffer: stop, r_multiple_target: r, forward_horizon_bars: horizon, entry_delay_bars: delay }
}.freeze

def load_base(cache_dir, symbol, base_key)
  raw_klines = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_klines_#{base_key}.json")))
  raw_funding = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_funding_365d.json")))
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  [DataWindow.research_slice(candles), DataWindow.research_slice(funding_series)]
end

store = ExperimentStore.new(EXPERIMENT_PATH)
total_per_pair = VARIANTS.values.sum { |v| v[:grid].size } * TRADE_GRID.size
puts "SuperTrend grid: #{VARIANTS.size} variants x ~4 param combos x #{TRADE_GRID.size} trade combos = #{total_per_pair} runs/TF-pair/symbol\n\n"

SYMBOLS.each do |symbol|
  profile = SymbolProfile.for(symbol)
  base_cache = {}

  TF_PAIRS.each do |pair|
    puts "── #{symbol} #{pair[:label]} ──────────────────────────────────────"

    base_candles, base_funding = (base_cache[pair[:base]] ||= load_base(CACHE_DIR, symbol, pair[:base]))
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
        flips = SupertrendFlipDetector.detect(supertrend_series, entry_candles)

        TRADE_GRID.each do |trade_params|
          idx += 1
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
            symbol: symbol,
            family: family,
            timeframe_pair: pair[:label],
            parameters: variant_params.merge(trade_params),
            walk_forward: result,
            phase: "mtf_walk_forward"
          )

          agg = result[:aggregate]
          next if agg[:note]

          printf "  [%3d/%d] %-22s trades=%-4d net_r=%-7s alpha=%-7s\n",
                 idx, total_per_pair, family, agg[:total_trades], agg[:pooled_net_expectancy_r].inspect, agg[:pooled_alpha_net_r].inspect
        end
      end
    end
  end
end

puts "\nDone — #{store.count} experiments in #{EXPERIMENT_PATH}"

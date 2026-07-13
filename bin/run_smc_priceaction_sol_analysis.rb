#!/usr/bin/env ruby
# frozen_string_literal: true

# Deep-dive: SMC structure signal (standalone, not blended into confluence)
# and pure price-action/ZigZag swings for SOLUSDT, same TF pairs, same
# explicit gating dimensions (trending_only, require_htf_alignment) as
# bin/run_supertrend_sol_analysis.rb, so all signal families are directly
# comparable in one leaderboard for SOLUSDT.
#
# "SMC standalone" = SmcStructureSignal's sweep/BOS direction flips, swept
# over structure_lookback (its own key parameter), via lib/smc_flip_detector.
# "Price action" = the existing ATR-relative ZigZag (SwingPointDetector) —
# this is what the "discovery" family already trades, swept here over
# min_move_atr_multiple (its own key parameter) with the same explicit
# gates for apples-to-apples comparison against supertrend's gated results.
#
# Records to the SAME experiments.jsonl, family: "smc_standalone" /
# "price_action", phase: "mtf_walk_forward" — ranked together with
# everything else by bin/validate_candidates.rb.
#
# Usage:
#   ruby bin/run_smc_priceaction_sol_analysis.rb

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
require_relative "../lib/swing_point_detector"
require_relative "../lib/smc_flip_detector"

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

GATE_COMBOS = [
  { trending_only: false, require_htf_alignment: false, label: "ungated" },
  { trending_only: true, require_htf_alignment: false, label: "trending_only" },
  { trending_only: false, require_htf_alignment: true, label: "htf_aligned" },
  { trending_only: true, require_htf_alignment: true, label: "trending+htf" }
].freeze

TRADE_GRID = [1.0].product([2.0, 3.0], [20], [1, 3]).map { |stop, r, horizon, delay|
  { stop_atr_buffer: stop, r_multiple_target: r, forward_horizon_bars: horizon, entry_delay_bars: delay }
}.freeze

SMC_STRUCTURE_LOOKBACKS = [10, 15, 20, 30].freeze
PRICE_ACTION_ZIGZAG_MULTIPLES = [1.0, 1.5, 2.0, 2.5].freeze

def load_base(cache_dir, symbol, base_key)
  raw_klines = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_klines_#{base_key}.json")))
  raw_funding = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_funding_365d.json")))
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  [DataWindow.research_slice(candles), DataWindow.research_slice(funding_series)]
end

def apply_gates(events, entry_regimes, aligned_htf, gate)
  events.select do |event|
    idx = event.confirmed_index
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
total_per_pair = (SMC_STRUCTURE_LOOKBACKS.size + PRICE_ACTION_ZIGZAG_MULTIPLES.size) * GATE_COMBOS.size * TRADE_GRID.size
puts "SOL SMC + price-action deep dive: #{total_per_pair} runs/TF-pair\n\n"

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

  run_family = lambda do |family, raw_events, extra_params, idx_ref|
    GATE_COMBOS.each do |gate|
      events = apply_gates(raw_events, entry_regimes, aligned_htf_regimes, gate)

      TRADE_GRID.each do |trade_params|
        idx_ref[0] += 1
        next if events.size < 20

        # Embargo sized to the actual lookback swept for this family (SMC's
        # structure_lookback), not the default profile value — the whole
        # point of the embargo is to be at least as wide as the indicator
        # window that could leak across the train/test boundary.
        embargo_bars = trade_params[:forward_horizon_bars] + (extra_params[:structure_lookback] || profile.structure_lookback)
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
          regimes: entry_regimes, swings: events, atr_cache: atr_cache, extractor: extractor
        ).evaluate(candles: entry_candles, funding_series: entry_funding, n_folds: pair[:n_folds], embargo_bars: embargo_bars)

        store.record(
          symbol: SYMBOL, family: family, timeframe_pair: pair[:label],
          parameters: extra_params.merge(trade_params).merge(gate: gate[:label]),
          walk_forward: result, phase: "mtf_walk_forward"
        )

        agg = result[:aggregate]
        next if agg[:note]

        printf "  [%4d/%d] %-16s gate=%-14s trades=%-4d net_r=%-7s alpha=%-7s\n",
               idx_ref[0], total_per_pair, family, gate[:label], agg[:total_trades], agg[:pooled_net_expectancy_r].inspect, agg[:pooled_alpha_net_r].inspect
      end
    end
  end

  idx_ref = [0]
  SMC_STRUCTURE_LOOKBACKS.each do |lookback|
    smc_profile = profile.dup
    smc_profile.structure_lookback = lookback
    raw_events = SmcFlipDetector.detect(entry_candles, smc_profile)
    run_family.call("smc_standalone", raw_events, { structure_lookback: lookback }, idx_ref)
  end

  PRICE_ACTION_ZIGZAG_MULTIPLES.each do |mult|
    raw_events = SwingPointDetector.new(min_move_atr_multiple: mult).detect(entry_candles)
    run_family.call("price_action", raw_events, { min_move_atr_multiple: mult }, idx_ref)
  end
end

puts "\nDone — #{store.count} experiments in #{EXPERIMENT_PATH}"

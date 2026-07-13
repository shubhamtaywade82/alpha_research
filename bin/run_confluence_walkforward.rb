#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 2 (confluence family): walk-forward OOS evaluation of the
# TrendFollowing + SMC structure + funding carry confluence engine, across
# MTF pairs (1h entry / 4h regime, 2h entry / 4h regime), confluence score
# thresholds, weight presets, and an optional HTF-alignment filter. Records
# results to the same experiment DB as the discovery-pipeline sweep
# (bin/run_multitimeframe_research.rb) with a shared field shape so
# bin/validate_candidates.rb can rank both families together.
#
# Usage:
#   ruby bin/run_confluence_walkforward.rb

require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/experiment_store"
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/indicators"
require_relative "../lib/candle_resampler"
require_relative "../lib/signals/trend_following_signal"
require_relative "../lib/signals/smc_structure_signal"
require_relative "../lib/signals/funding_carry_signal"
require_relative "../lib/confluence_scorer"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/move_labeler"
require_relative "../lib/trade_cost_model"
require_relative "../lib/walk_forward_validator"
require_relative "../lib/data_window"

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
CACHE_DIR = File.join(root, "data", "cache")
EXPERIMENT_PATH = File.join(root, "data", "experiments.jsonl")

TF_PAIRS = [
  { entry_label: "1h", entry_factor: 1, htf_factor: 4, htf_label: "4h" },
  { entry_label: "2h", entry_factor: 2, htf_factor: 4, htf_label: "4h" }
].freeze

THRESHOLDS = [0.55, 0.65, 0.75].freeze
WEIGHT_PRESETS = {
  "profile_default" => nil,
  "trend_heavy" => { trend: 0.6, structure: 0.3, funding: 0.1 }
}.freeze
REQUIRE_HTF_OPTIONS = [true, false].freeze

FORWARD_HORIZON_BARS = 20
STOP_ATR_BUFFER = 1.0
R_TARGET = 2.0
FEE_BPS_PER_SIDE = 4.0
SLIPPAGE_BPS_PER_SIDE = 2.0

ConfluenceTrade = Struct.new(:direction, :entry_price, :stop_price, :entry_index, :exit_index, :r_multiple, keyword_init: true)

def mean(values)
  vals = values.compact
  return nil if vals.empty?

  vals.sum / vals.size.to_f
end

def build_engine(profile, threshold)
  {
    trend: TrendFollowingSignal.new(profile),
    structure: SmcStructureSignal.new(profile),
    funding: FundingCarrySignal.new(profile),
    scorer: ConfluenceScorer.new(profile, min_score_threshold: threshold)
  }
end

def simulate_trades(engine:, entry_candles:, entry_regimes:, ema_fast_series:, entry_funding:,
                     atr_series:, aligned_htf:, require_htf:, range:)
  trades = []
  range.each do |idx|
    next if idx + FORWARD_HORIZON_BARS >= entry_candles.size

    regime = entry_regimes[idx]
    next if regime.nil?

    if require_htf
      htf = aligned_htf[idx]
      next if htf.nil? || htf.state != regime.state
    end

    candle = entry_candles[idx]
    trend = engine[:trend].evaluate(regime: regime, candle: candle, ema_fast_val: ema_fast_series[idx], ema_slow_val: nil)
    structure = engine[:structure].evaluate(candles: entry_candles[0..idx], index: idx)
    funding = engine[:funding].evaluate(funding_rate: entry_funding[idx])
    candidate = engine[:scorer].score(trend: trend, structure: structure, funding: funding)
    next if candidate.direction == :none

    atr = atr_series[idx]
    next if atr.nil? || atr <= 0

    entry_price = candle[:close]
    stop_price = candidate.direction == :long ? entry_price - atr * STOP_ATR_BUFFER : entry_price + atr * STOP_ATR_BUFFER
    stop_dist = (entry_price - stop_price).abs
    next if stop_dist <= 0

    target_price = candidate.direction == :long ? entry_price + stop_dist * R_TARGET : entry_price - stop_dist * R_TARGET
    exit_index = nil
    exit_price = nil
    gross_r = nil
    last_bar = [idx + FORWARD_HORIZON_BARS, entry_candles.size - 1].min

    ((idx + 1)..last_bar).each do |i|
      bar = entry_candles[i]
      if candidate.direction == :long
        if bar[:low] <= stop_price
          exit_index, exit_price, gross_r = i, stop_price, -1.0
          break
        elsif bar[:high] >= target_price
          exit_index, exit_price, gross_r = i, target_price, R_TARGET
          break
        end
      else
        if bar[:high] >= stop_price
          exit_index, exit_price, gross_r = i, stop_price, -1.0
          break
        elsif bar[:low] <= target_price
          exit_index, exit_price, gross_r = i, target_price, R_TARGET
          break
        end
      end
    end

    unless exit_index
      exit_index = last_bar
      exit_price = entry_candles[last_bar][:close]
      move = candidate.direction == :long ? exit_price - entry_price : entry_price - exit_price
      gross_r = move / stop_dist
    end

    trades << { regime_state: regime.state, trade: ConfluenceTrade.new(
      direction: candidate.direction, entry_price: entry_price, stop_price: stop_price,
      entry_index: idx, exit_index: exit_index, r_multiple: gross_r.round(3)
    ) }
  end
  trades
end

store = ExperimentStore.new(EXPERIMENT_PATH)
total_configs = THRESHOLDS.size * WEIGHT_PRESETS.size * REQUIRE_HTF_OPTIONS.size

SYMBOLS.each do |symbol|
  profile = SymbolProfile.for(symbol)
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_klines_1h_365d.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_365d.json")))
  base_candles_full = BinanceDataLoader.klines_to_candles(raw_klines)
  base_funding_full = BinanceDataLoader.align_funding_series(base_candles_full, raw_funding)
  base_candles = DataWindow.research_slice(base_candles_full)
  base_funding = DataWindow.research_slice(base_funding_full)

  TF_PAIRS.each do |pair|
    puts "── #{symbol} confluence #{pair[:entry_label]}+#{pair[:htf_label]} ──"

    entry_candles = CandleResampler.resample_candles(base_candles, pair[:entry_factor])
    entry_funding = CandleResampler.resample_series(base_funding, pair[:entry_factor])
    htf_candles = CandleResampler.resample_candles(base_candles, pair[:htf_factor])
    next if entry_candles.size < 400 || htf_candles.size < 100

    entry_regimes = RegimeClassifier.new(profile).classify(entry_candles)
    htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
    aligned_htf = CandleResampler.align_higher_regimes(lower_candles: entry_candles, higher_candles: htf_candles, higher_regimes: htf_regimes)
    ema_fast_series = Indicators.ema(entry_candles.map { |c| c[:close] }, profile.ema_fast)
    atr_series = Indicators.atr(entry_candles, 14)

    extractor = ContextFeatureExtractor.new(profile)
    extractor.ema_cache_fast = ema_fast_series
    extractor.ema_cache_slow = Indicators.ema(entry_candles.map { |c| c[:close] }, profile.ema_slow)
    baseline_labeler = MoveLabeler.new(atr_period: 14, stop_atr_buffer: STOP_ATR_BUFFER, r_multiple_target: R_TARGET, atr_cache: atr_series)
    baseline_samples = baseline_labeler.label_baseline_samples(
      candles: entry_candles, regimes: entry_regimes, funding_series: entry_funding,
      feature_extractor: extractor, forward_horizon_bars: FORWARD_HORIZON_BARS, stride: 5
    )

    bar_minutes = pair[:entry_label] == "1h" ? 60 : 120
    cost_model = TradeCostModel.new(fee_bps_per_side: FEE_BPS_PER_SIDE, slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE, bar_interval_minutes: bar_minutes)
    n_folds = pair[:entry_label] == "1h" ? 8 : 6
    embargo_bars = FORWARD_HORIZON_BARS + profile.structure_lookback
    folds = WalkForwardValidator.build_folds(total_bars: entry_candles.size, n_folds: n_folds, embargo_bars: embargo_bars)

    idx = 0
    THRESHOLDS.each do |threshold|
      WEIGHT_PRESETS.each do |preset_name, weights|
        prof = profile.dup
        if weights
          prof.weight_trend = weights[:trend]
          prof.weight_structure = weights[:structure]
          prof.weight_funding_carry = weights[:funding]
        end
        engine = build_engine(prof, threshold)

        REQUIRE_HTF_OPTIONS.each do |require_htf|
          idx += 1
          fold_results = folds.map do |fold|
            bucket_trades = simulate_trades(
              engine: engine, entry_candles: entry_candles, entry_regimes: entry_regimes,
              ema_fast_series: ema_fast_series, entry_funding: entry_funding, atr_series: atr_series,
              aligned_htf: aligned_htf, require_htf: require_htf, range: fold.test_range
            )
            next { trade_count: 0 } if bucket_trades.empty?

            grouped = bucket_trades.group_by { |bt| bt[:regime_state] }
            fold_baselines = baseline_samples.select { |s| fold.test_range.cover?(s.index) }

            bucket_alpha = grouped.map do |regime_state, entries|
              dominant_direction = entries.group_by { |e| e[:trade].direction }.max_by { |_, v| v.size }&.first
              net_rs = entries.map { |e| cost_model.net_r_for_event(event: e[:trade], funding_series: entry_funding) }
              baseline_pool = fold_baselines.select { |s| s.context[:regime_state] == regime_state }
              baseline_net_rs = baseline_pool.map { |s| cost_model.net_r_for_baseline(sample: s, direction: dominant_direction, funding_series: entry_funding) }
              { net_mean: mean(net_rs), baseline_mean: mean(baseline_net_rs), n: net_rs.size, net_rs: net_rs }
            end

            all_net = bucket_alpha.flat_map { |b| b[:net_rs] }
            alpha_values = bucket_alpha.filter_map { |b| b[:net_mean] && b[:baseline_mean] ? b[:net_mean] - b[:baseline_mean] : nil }

            {
              trade_count: all_net.size,
              net_expectancy_r: mean(all_net),
              alpha_net_r: mean(alpha_values),
              win_rate: all_net.empty? ? nil : all_net.count(&:positive?) / all_net.size.to_f,
              net_rs: all_net,
              baseline_net_rs: bucket_alpha.flat_map { |b| Array.new(b[:n], b[:baseline_mean]) }
            }
          end

          valid = fold_results.reject { |f| f[:trade_count].zero? }
          aggregate =
            if valid.empty?
              { note: "no OOS trades generated across any fold" }
            else
              pooled_net = valid.flat_map { |f| f[:net_rs] }
              pooled_baseline = valid.flat_map { |f| f[:baseline_net_rs] }.compact
              {
                total_folds: folds.size,
                folds_with_trades: valid.size,
                total_trades: valid.sum { |f| f[:trade_count] },
                # See lib/walk_forward_discovery_evaluator.rb comment: mean_*
                # is an unweighted per-fold average (Simpson's-paradox risk
                # when fold trade counts differ a lot); pooled_* is the
                # trade-count-weighted truth. Prefer pooled_* downstream.
                mean_net_expectancy_r: mean(valid.map { |f| f[:net_expectancy_r] })&.round(3),
                mean_alpha_net_r: mean(valid.map { |f| f[:alpha_net_r] }.compact)&.round(3),
                mean_win_rate: mean(valid.map { |f| f[:win_rate] })&.round(3),
                pooled_net_expectancy_r: mean(pooled_net)&.round(3),
                pooled_alpha_net_r: (mean(pooled_net) && mean(pooled_baseline) ? (mean(pooled_net) - mean(pooled_baseline)).round(3) : nil),
                pooled_win_rate: pooled_net.empty? ? nil : (pooled_net.count(&:positive?) / pooled_net.size.to_f).round(3),
                folds_with_positive_alpha: valid.count { |f| f[:alpha_net_r] && f[:alpha_net_r].positive? }
              }
            end

          store.record(
            symbol: symbol,
            family: "confluence",
            timeframe_pair: "#{pair[:entry_label]}+#{pair[:htf_label]}",
            parameters: { min_score_threshold: threshold, weight_preset: preset_name, require_htf_alignment: require_htf,
                          stop_atr_buffer: STOP_ATR_BUFFER, r_multiple_target: R_TARGET, forward_horizon_bars: FORWARD_HORIZON_BARS },
            walk_forward: { aggregate: aggregate },
            phase: "confluence_walk_forward"
          )

          note = aggregate[:note] || format("trades=%d net_r=%s alpha=%s wr=%s",
                                             aggregate[:total_trades], aggregate[:mean_net_expectancy_r].inspect,
                                             aggregate[:mean_alpha_net_r].inspect, aggregate[:mean_win_rate].inspect)
          printf "  [%2d/%d] thr=%.2f preset=%-15s htf=%-5s  %s\n", idx, total_configs, threshold, preset_name, require_htf, note
        end
      end
    end
  end
end

puts "\nDone — #{store.count} experiments in #{EXPERIMENT_PATH}"

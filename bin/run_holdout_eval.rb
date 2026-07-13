#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 5: run the FROZEN finalist list once against the untouched holdout
# slice (final 20% of each series — never used in Phase 0-4). No parameter
# changes are permitted after this runs; a finalist that fails here is
# reported as FAILED, not tuned away.
#
# Usage:
#   ruby bin/run_holdout_eval.rb

require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/trade_cost_model"
require_relative "../lib/candle_resampler"
require_relative "../lib/swing_point_detector"
require_relative "../lib/indicators"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/move_labeler"
require_relative "../lib/data_window"
require_relative "../lib/signals/trend_following_signal"
require_relative "../lib/signals/smc_structure_signal"
require_relative "../lib/signals/funding_carry_signal"
require_relative "../lib/confluence_scorer"
require_relative "../lib/supertrend_calculator"
require_relative "../lib/supertrend_flip_detector"

SUPERTREND_BUILDERS = {
  "supertrend_percentile" => ->(candles, p) { SupertrendCalculator.percentile_scaled(candles, atr_period: p["atr_period"], min_mult: p["min_mult"], max_mult: p["max_mult"], pct_lookback: 100) },
  "supertrend_kmeans" => ->(candles, p) { SupertrendCalculator.kmeans_clustered(candles, atr_period: p["atr_period"], cluster_lookback: 100, mult_low: p["mult_low"], mult_mid: p["mult_mid"], mult_high: p["mult_high"]) },
  "supertrend_adaptive" => ->(candles, p) { SupertrendCalculator.fully_adaptive(candles, base_period: p["base_period"], min_period: p["min_period"], max_period: p["max_period"], min_mult: p["min_mult"], max_mult: p["max_mult"], er_lookback: p["er_lookback"], pct_lookback: 100) }
}.freeze

def events_for(family, entry_candles, params)
  if SUPERTREND_BUILDERS.key?(family)
    series = SUPERTREND_BUILDERS[family].call(entry_candles, params)
    SupertrendFlipDetector.detect(series, entry_candles)
  else
    SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(entry_candles)
  end
end

CACHE_DIR = File.join(root, "data", "cache")
FINALISTS_PATH = File.join(root, "data", "finalists.json")
HOLDOUT_RESULTS_PATH = File.join(root, "data", "holdout_results.json")

FEE_BPS_PER_SIDE = 4.0
SLIPPAGE_BPS_PER_SIDE = 2.0

TF_PAIR_DEFS = {
  "15m+1h" => { base: "15m_180d", base_minutes: 15, entry_factor: 1, htf_factor: 4, htf_label: "1h" },
  "15m+4h" => { base: "15m_180d", base_minutes: 15, entry_factor: 1, htf_factor: 16, htf_label: "4h" },
  "1h+4h" => { base: "1h_365d", base_minutes: 60, entry_factor: 1, htf_factor: 4, htf_label: "4h" },
  "2h+4h" => { base: "1h_365d", base_minutes: 60, entry_factor: 2, htf_factor: 4, htf_label: "4h" },
  "4h+1d" => { base: "1h_365d", base_minutes: 60, entry_factor: 4, htf_factor: 24, htf_label: "1d" }
}.freeze

unless File.exist?(FINALISTS_PATH)
  puts "No finalists found at #{FINALISTS_PATH}. Run bin/validate_candidates.rb first."
  exit 1
end

finalists = JSON.parse(File.read(FINALISTS_PATH))
if finalists.empty?
  puts "finalists.json is empty — no config cleared the stability gate. Nothing to hold out."
  exit 0
end

base_cache = {}

def load_holdout(cache_dir, symbol, base_key)
  raw_klines = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_klines_#{base_key}.json")))
  raw_funding = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_funding_365d.json")))
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  [DataWindow.holdout_slice(candles), DataWindow.holdout_slice(funding_series)]
end

def mean(values)
  vals = values.compact
  return nil if vals.empty?

  vals.sum / vals.size.to_f
end

# Discovery family: apply the finalist's own tradeable buckets+directions
# (frozen from Phase 2/3 training) directly on holdout candles — no
# re-discovery, no re-fitting, exactly the "confirm on unseen data" test.
def discovery_holdout_trades(finalist, cache_dir, base_cache)
  pair = TF_PAIR_DEFS.fetch(finalist["timeframe_pair"])
  symbol = finalist["symbol"]
  profile = SymbolProfile.for(symbol)
  p = finalist["parameters"]

  base_candles, base_funding = (base_cache[[symbol, pair[:base]]] ||= load_holdout(cache_dir, symbol, pair[:base]))
  entry_candles = CandleResampler.resample_candles(base_candles, pair[:entry_factor])
  entry_funding = CandleResampler.resample_series(base_funding, pair[:entry_factor])
  htf_candles = CandleResampler.resample_candles(base_candles, pair[:htf_factor])
  return [] if entry_candles.size < 100 || htf_candles.size < 20

  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_htf = CandleResampler.align_higher_regimes(lower_candles: entry_candles, higher_candles: htf_candles, higher_regimes: htf_regimes)
  entry_regimes = RegimeClassifier.new(profile).classify(entry_candles)
  swings = events_for(finalist["family"], entry_candles, p)
  closes = entry_candles.map { |c| c[:close] }
  extractor = ContextFeatureExtractor.new(profile)
  extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
  extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)

  profile_for_run = profile.dup
  profile_for_run.r_multiple_target = p["r_multiple_target"]
  labeler = MoveLabeler.new(atr_period: 14, stop_atr_buffer: p["stop_atr_buffer"], r_multiple_target: p["r_multiple_target"])
  events = labeler.label_signal_events(
    candles: entry_candles, swings: swings, regimes: entry_regimes, funding_series: entry_funding,
    feature_extractor: extractor, entry_delay_bars: p["entry_delay_bars"], forward_horizon_bars: p["forward_horizon_bars"],
    htf_regimes: aligned_htf
  )

  htf_label = pair[:htf_label]
  bucket_directions = (finalist["tradeable_buckets"] || []).each_with_object({}) { |b, h| h[b["bucket_key"]] = b["direction"] }
  cost_model = TradeCostModel.new(fee_bps_per_side: FEE_BPS_PER_SIDE, slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE,
                                   bar_interval_minutes: pair[:base_minutes] * pair[:entry_factor])

  events.filter_map do |event|
    htf = event.context.key?(:htf_aligned) ? event.context[:htf_aligned] : :unknown
    bucket_key = "#{event.context[:regime_state]}|#{htf_label}_aligned=#{htf}"
    expected_direction = bucket_directions[bucket_key]
    next nil if expected_direction.nil? || expected_direction != event.direction.to_s

    net_r = cost_model.net_r_for_event(event: event, funding_series: entry_funding)
    { symbol: symbol, entry_ts: event.entry_ts, net_r: net_r, direction: event.direction }
  end
end

def confluence_holdout_trades(finalist, cache_dir, base_cache)
  pair_label = finalist["timeframe_pair"]
  entry_label, _ = pair_label.split("+")
  entry_factor = entry_label == "1h" ? 1 : 2
  symbol = finalist["symbol"]
  profile = SymbolProfile.for(symbol)
  p = finalist["parameters"]

  base_candles, base_funding = (base_cache[[symbol, "1h_365d"]] ||= load_holdout(cache_dir, symbol, "1h_365d"))
  entry_candles = CandleResampler.resample_candles(base_candles, entry_factor)
  entry_funding = CandleResampler.resample_series(base_funding, entry_factor)
  htf_candles = CandleResampler.resample_candles(base_candles, 4)
  return [] if entry_candles.size < 100 || htf_candles.size < 20

  entry_regimes = RegimeClassifier.new(profile).classify(entry_candles)
  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_htf = CandleResampler.align_higher_regimes(lower_candles: entry_candles, higher_candles: htf_candles, higher_regimes: htf_regimes)
  ema_fast_series = Indicators.ema(entry_candles.map { |c| c[:close] }, profile.ema_fast)
  atr_series = Indicators.atr(entry_candles, 14)

  prof = profile.dup
  if p["weight_preset"] == "trend_heavy"
    prof.weight_trend = 0.6
    prof.weight_structure = 0.3
    prof.weight_funding_carry = 0.1
  end
  trend_signal = TrendFollowingSignal.new(prof)
  structure_signal = SmcStructureSignal.new(prof)
  funding_signal = FundingCarrySignal.new(prof)
  scorer = ConfluenceScorer.new(prof, min_score_threshold: p["min_score_threshold"])
  cost_model = TradeCostModel.new(fee_bps_per_side: FEE_BPS_PER_SIDE, slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE,
                                   bar_interval_minutes: entry_label == "1h" ? 60 : 120)

  trades = []
  (0...entry_candles.size).each do |idx|
    next if idx + p["forward_horizon_bars"] >= entry_candles.size

    regime = entry_regimes[idx]
    next if regime.nil?

    if p["require_htf_alignment"]
      htf = aligned_htf[idx]
      next if htf.nil? || htf.state != regime.state
    end

    candle = entry_candles[idx]
    trend = trend_signal.evaluate(regime: regime, candle: candle, ema_fast_val: ema_fast_series[idx], ema_slow_val: nil)
    structure = structure_signal.evaluate(candles: entry_candles[0..idx], index: idx)
    funding = funding_signal.evaluate(funding_rate: entry_funding[idx])
    candidate = scorer.score(trend: trend, structure: structure, funding: funding)
    next if candidate.direction == :none

    atr = atr_series[idx]
    next if atr.nil? || atr <= 0

    entry_price = candle[:close]
    stop_price = candidate.direction == :long ? entry_price - atr * p["stop_atr_buffer"] : entry_price + atr * p["stop_atr_buffer"]
    stop_dist = (entry_price - stop_price).abs
    next if stop_dist <= 0

    target_price = candidate.direction == :long ? entry_price + stop_dist * p["r_multiple_target"] : entry_price - stop_dist * p["r_multiple_target"]
    exit_index = nil
    exit_price = nil
    gross_r = nil
    last_bar = [idx + p["forward_horizon_bars"], entry_candles.size - 1].min

    ((idx + 1)..last_bar).each do |i|
      bar = entry_candles[i]
      if candidate.direction == :long
        if bar[:low] <= stop_price
          exit_index, exit_price, gross_r = i, stop_price, -1.0
          break
        elsif bar[:high] >= target_price
          exit_index, exit_price, gross_r = i, target_price, p["r_multiple_target"]
          break
        end
      else
        if bar[:high] >= stop_price
          exit_index, exit_price, gross_r = i, stop_price, -1.0
          break
        elsif bar[:low] <= target_price
          exit_index, exit_price, gross_r = i, target_price, p["r_multiple_target"]
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

    event = Struct.new(:direction, :entry_price, :stop_price, :entry_index, :exit_index, :r_multiple).new(
      candidate.direction, entry_price, stop_price, idx, exit_index, gross_r.round(3)
    )
    net_r = cost_model.net_r_for_event(event: event, funding_series: entry_funding)
    trades << { symbol: symbol, entry_ts: candle[:ts], net_r: net_r, direction: candidate.direction }
  end
  trades
end

puts "Running FROZEN finalists once against the untouched holdout slice (never seen before)..."
puts

report = finalists.map do |finalist|
  trades = finalist["family"] == "confluence" ? confluence_holdout_trades(finalist, CACHE_DIR, base_cache) : discovery_holdout_trades(finalist, CACHE_DIR, base_cache)
  net_rs = trades.map { |t| t[:net_r] }
  holdout_expectancy = mean(net_rs)
  holdout_win_rate = net_rs.empty? ? nil : net_rs.count(&:positive?) / net_rs.size.to_f
  sharpe = nil
  if net_rs.size > 5
    m = mean(net_rs)
    std = Math.sqrt(net_rs.sum { |v| (v - m)**2 } / net_rs.size.to_f)
    sharpe = std.zero? ? 0.0 : m / std
  end
  cumulative = 0.0
  peak = 0.0
  max_dd = 0.0
  net_rs.each do |r|
    cumulative += r
    peak = [peak, cumulative].max
    max_dd = [max_dd, peak - cumulative].max
  end

  status = if net_rs.empty?
             "NO_TRADES"
           elsif holdout_expectancy && holdout_expectancy.positive?
             "PASSED"
           else
             "FAILED"
           end

  result = {
    symbol: finalist["symbol"], family: finalist["family"], timeframe_pair: finalist["timeframe_pair"],
    research_alpha_net_r: finalist["pooled_alpha_net_r"], research_net_expectancy_r: finalist["pooled_net_expectancy_r"],
    holdout_trades: net_rs.size, holdout_net_expectancy_r: holdout_expectancy&.round(3),
    holdout_win_rate: holdout_win_rate&.round(3), holdout_sharpe: sharpe&.round(3),
    holdout_max_drawdown_r: max_dd.round(3), status: status
  }

  puts format("%-9s %-11s %-10s research_R=%+6.3f  holdout_R=%s  trades=%-4d  status=%s",
              result[:symbol], result[:family], result[:timeframe_pair], result[:research_alpha_net_r] || 0.0,
              result[:holdout_net_expectancy_r].inspect, result[:holdout_trades], result[:status])
  result
end

File.write(HOLDOUT_RESULTS_PATH, JSON.pretty_generate(report))
puts "\nHoldout results written to #{HOLDOUT_RESULTS_PATH}"

passed = report.count { |r| r[:status] == "PASSED" }
puts "\n#{passed}/#{report.size} finalists PASSED holdout (positive net expectancy on unseen data)."
puts "This is the honest, final answer — no further tuning is valid after this run." if report.any?

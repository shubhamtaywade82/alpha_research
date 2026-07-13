#!/usr/bin/env ruby
# frozen_string_literal: true

# Paper-trading bot for the 5 holdout-confirmed strategies from the alpha
# research campaign (see data/CAMPAIGN_REPORT.md). No real orders are ever
# placed — this only reads public Binance market data and simulates fills
# against a persisted virtual $10k account (data/paper_trading_state.json).
#
# Reuses the EXACT same signal/regime/cost classes the backtest validated
# (RegimeClassifier, TrendFollowingSignal, SmcStructureSignal,
# FundingCarrySignal, ConfluenceScorer, SwingPointDetector,
# SupertrendCalculator, SupertrendFlipDetector, TradeCostModel) — no
# reimplementation of strategy logic, only a live polling shell around it.
#
# Usage (run this on a schedule — e.g. cron every 15 min, or a loop):
#   ruby bin/paper_trading_bot.rb
#
# It fetches the last ~30 days of 1h candles each tick (cheap, single
# Binance REST call per symbol) and only acts on bars that have fully
# closed — the currently-forming candle is always dropped.

require "json"
require "time"

root = File.expand_path("..", __dir__)
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/candle_resampler"
require_relative "../lib/swing_point_detector"
require_relative "../lib/indicators"
require_relative "../lib/signals/trend_following_signal"
require_relative "../lib/signals/smc_structure_signal"
require_relative "../lib/signals/funding_carry_signal"
require_relative "../lib/confluence_scorer"
require_relative "../lib/supertrend_calculator"
require_relative "../lib/supertrend_flip_detector"
require_relative "../lib/paper_broker"

STATE_PATH = File.join(root, "data", "paper_trading_state.json")
DAYS_BACK = 30
BASE_INTERVAL_SECONDS = 3600 # native fetch is always 1h; resampled for 2h/4h below

# The 5 strategies recommended in data/CAMPAIGN_REPORT.md, exact params from
# data/finalists_deduped.json. Each has a stable strategy_id used for dedup
# and position tracking in PaperBroker's persisted state.
STRATEGIES = [
  {
    id: "sol_confluence_2h4h", symbol: "SOLUSDT", family: "confluence",
    entry_factor: 2, htf_factor: 4, htf_label: "4h",
    min_score_threshold: 0.55, weight_preset: "trend_heavy", require_htf_alignment: false,
    stop_atr_buffer: 1.0, r_multiple_target: 2.0, forward_horizon_bars: 20
  },
  {
    id: "xrp_confluence_2h4h", symbol: "XRPUSDT", family: "confluence",
    entry_factor: 2, htf_factor: 4, htf_label: "4h",
    min_score_threshold: 0.65, weight_preset: "trend_heavy", require_htf_alignment: true,
    stop_atr_buffer: 1.0, r_multiple_target: 2.0, forward_horizon_bars: 20
  },
  {
    id: "sol_discovery_1h4h", symbol: "SOLUSDT", family: "discovery",
    entry_factor: 1, htf_factor: 4, htf_label: "4h",
    stop_atr_buffer: 1.0, r_multiple_target: 3.0, forward_horizon_bars: 40, entry_delay_bars: 3,
    tradeable_buckets: {
      "high_vol_range|4h_aligned=false" => "short",
      "trending_bear|4h_aligned=false" => "long"
    }
  },
  {
    id: "xrp_supertrend_kmeans_1h4h", symbol: "XRPUSDT", family: "supertrend_kmeans",
    entry_factor: 1, htf_factor: 4, htf_label: "4h",
    atr_period: 14, mult_low: 1.0, mult_mid: 2.0, mult_high: 3.0,
    stop_atr_buffer: 1.0, r_multiple_target: 3.0, forward_horizon_bars: 20, entry_delay_bars: 1,
    tradeable_buckets: {
      "trending_bear|4h_aligned=true" => "long",
      "low_vol_range|4h_aligned=false" => "long"
    }
  },
  {
    id: "xrp_supertrend_adaptive_1h4h", symbol: "XRPUSDT", family: "supertrend_adaptive",
    entry_factor: 1, htf_factor: 4, htf_label: "4h",
    base_period: 14, min_period: 7, max_period: 21, min_mult: 1.5, max_mult: 3.0, er_lookback: 10,
    stop_atr_buffer: 1.0, r_multiple_target: 3.0, forward_horizon_bars: 20, entry_delay_bars: 3,
    tradeable_buckets: {
      "trending_bear|4h_aligned=true" => "long"
    }
  }
].freeze

SUPERTREND_BUILDERS = {
  "supertrend_kmeans" => ->(candles, s) { SupertrendCalculator.kmeans_clustered(candles, atr_period: s[:atr_period], cluster_lookback: 100, mult_low: s[:mult_low], mult_mid: s[:mult_mid], mult_high: s[:mult_high]) },
  "supertrend_adaptive" => ->(candles, s) { SupertrendCalculator.fully_adaptive(candles, base_period: s[:base_period], min_period: s[:min_period], max_period: s[:max_period], min_mult: s[:min_mult], max_mult: s[:max_mult], er_lookback: s[:er_lookback], pct_lookback: 100) }
}.freeze

def fetch_closed_candles(symbol, days_back)
  raw_klines = BinanceDataLoader.fetch_klines(symbol: symbol, interval: "1h", days_back: days_back)
  raw_funding = BinanceDataLoader.fetch_funding_rate_history(symbol: symbol, days_back: days_back)
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)

  # Drop the currently-forming bar: its close_ts (open + 1h) must be <= now.
  now = Time.now.to_i
  cutoff = candles.rindex { |c| c[:ts] + BASE_INTERVAL_SECONDS <= now }
  return [[], []] if cutoff.nil?

  [candles[0..cutoff], funding_series[0..cutoff]]
end

def build_confluence_engine(profile, strategy)
  prof = profile.dup
  if strategy[:weight_preset] == "trend_heavy"
    prof.weight_trend = 0.6
    prof.weight_structure = 0.3
    prof.weight_funding_carry = 0.1
  end
  {
    trend: TrendFollowingSignal.new(prof),
    structure: SmcStructureSignal.new(prof),
    funding: FundingCarrySignal.new(prof),
    scorer: ConfluenceScorer.new(prof, min_score_threshold: strategy[:min_score_threshold])
  }
end

def evaluate_confluence_entry(strategy, entry_candles, entry_regimes, ema_fast_series, entry_funding, atr_series, aligned_htf, engine)
  idx = entry_candles.size - 1
  regime = entry_regimes[idx]
  return nil if regime.nil?

  if strategy[:require_htf_alignment]
    htf = aligned_htf[idx]
    return nil if htf.nil? || htf.state != regime.state
  end

  candle = entry_candles[idx]
  trend = engine[:trend].evaluate(regime: regime, candle: candle, ema_fast_val: ema_fast_series[idx], ema_slow_val: nil)
  structure = engine[:structure].evaluate(candles: entry_candles[0..idx], index: idx)
  funding = engine[:funding].evaluate(funding_rate: entry_funding[idx])
  candidate = engine[:scorer].score(trend: trend, structure: structure, funding: funding)
  return nil if candidate.direction == :none

  atr = atr_series[idx]
  return nil if atr.nil? || atr <= 0

  { direction: candidate.direction, entry_price: candle[:close], entry_ts: candle[:ts], atr: atr }
end

def evaluate_discovery_entry(strategy, entry_candles, entry_regimes, aligned_htf, swings, atr_series)
  idx = entry_candles.size - 1
  scheduled_swing = swings.find { |s| s.confirmed_index + strategy[:entry_delay_bars] == idx }
  return nil if scheduled_swing.nil?

  regime = entry_regimes[idx]
  return nil if regime.nil?

  htf = aligned_htf[idx]
  htf_state = htf.nil? ? :unknown : htf.state
  bucket_key = "#{regime.state}|#{strategy[:htf_label]}_aligned=#{htf_state == regime.state}"
  expected_direction = strategy[:tradeable_buckets][bucket_key]
  direction = scheduled_swing.type == :low ? :long : :short
  return nil if expected_direction.nil? || expected_direction != direction.to_s

  atr = atr_series[idx]
  return nil if atr.nil? || atr <= 0

  { direction: direction, entry_price: entry_candles[idx][:close], entry_ts: entry_candles[idx][:ts], atr: atr }
end

def funding_sum_for(funding_series, candles, start_ts, end_ts)
  start_idx = candles.index { |c| c[:ts] >= start_ts } || 0
  end_idx = candles.rindex { |c| c[:ts] <= end_ts } || (candles.size - 1)
  return 0.0 if end_idx < start_idx

  funding_series[start_idx..end_idx].compact.sum.to_f
end

broker = PaperBroker.new(state_path: STATE_PATH)
puts "=" * 70
puts "Paper trading tick — #{Time.now.utc.iso8601}"
puts "=" * 70

base_cache = {}
STRATEGIES.each do |strategy|
  symbol = strategy[:symbol]
  profile = SymbolProfile.for(symbol)

  begin
    base_candles, base_funding = (base_cache[symbol] ||= fetch_closed_candles(symbol, DAYS_BACK))
  rescue StandardError => e
    puts "#{strategy[:id]}: fetch failed (#{e.class}: #{e.message}) — skipping this tick, will retry next tick"
    next
  end
  if base_candles.size < 200
    puts "#{strategy[:id]}: insufficient candles (#{base_candles.size}), skipping this tick"
    next
  end

  entry_candles = CandleResampler.resample_candles(base_candles, strategy[:entry_factor])
  entry_funding = CandleResampler.resample_series(base_funding, strategy[:entry_factor])
  htf_candles = CandleResampler.resample_candles(base_candles, strategy[:htf_factor])
  interval_seconds = BASE_INTERVAL_SECONDS * strategy[:entry_factor]

  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_htf = CandleResampler.align_higher_regimes(lower_candles: entry_candles, higher_candles: htf_candles, higher_regimes: htf_regimes)
  entry_regimes = RegimeClassifier.new(profile).classify(entry_candles)
  atr_series = Indicators.atr(entry_candles, 14)

  latest_ts = entry_candles.last[:ts]

  # 1. Manage existing open positions for this strategy against new bars.
  broker.open_positions_for(strategy[:id]).dup.each do |position|
    new_bars = entry_candles.select { |c| c[:ts] > position["last_checked_ts"] }
    next if new_bars.empty?

    funding_sum = funding_sum_for(entry_funding, entry_candles, position["last_checked_ts"] + 1, latest_ts)
    broker.process_bars_for_position!(position, new_bars, funding_sum: funding_sum)
  end

  # 2. Look for a new entry, but only once per bar (dedup by timestamp, not index).
  if broker.last_processed_entry_ts(strategy[:id]) == latest_ts
    puts "#{strategy[:id]}: bar #{Time.at(latest_ts).utc} already processed"
    next
  end
  broker.mark_entry_checked(strategy[:id], latest_ts)

  entry =
    if strategy[:family] == "confluence"
      engine = build_confluence_engine(profile, strategy)
      closes = entry_candles.map { |c| c[:close] }
      ema_fast_series = Indicators.ema(closes, profile.ema_fast)
      evaluate_confluence_entry(strategy, entry_candles, entry_regimes, ema_fast_series, entry_funding, atr_series, aligned_htf, engine)
    elsif SUPERTREND_BUILDERS.key?(strategy[:family])
      series = SUPERTREND_BUILDERS[strategy[:family]].call(entry_candles, strategy)
      swings = SupertrendFlipDetector.detect(series, entry_candles)
      evaluate_discovery_entry(strategy, entry_candles, entry_regimes, aligned_htf, swings, atr_series)
    else
      swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(entry_candles)
      evaluate_discovery_entry(strategy, entry_candles, entry_regimes, aligned_htf, swings, atr_series)
    end

  if entry.nil?
    puts "#{strategy[:id]}: no signal on bar #{Time.at(latest_ts).utc}"
  elsif broker.open_position_for?(symbol, strategy[:id])
    puts "#{strategy[:id]}: signal fired but a position is already open — skipping (one position per strategy)"
  else
    stop_price = entry[:direction] == :long ? entry[:entry_price] - entry[:atr] * strategy[:stop_atr_buffer] \
                                             : entry[:entry_price] + entry[:atr] * strategy[:stop_atr_buffer]
    broker.open_position(
      symbol: symbol, strategy_id: strategy[:id], direction: entry[:direction],
      entry_ts: entry[:entry_ts], entry_price: entry[:entry_price], stop_price: stop_price,
      r_multiple_target: strategy[:r_multiple_target], horizon_bars: strategy[:forward_horizon_bars],
      interval_seconds: interval_seconds
    )
  end
end

broker.save!
puts "\nAccount summary: #{broker.summary}"

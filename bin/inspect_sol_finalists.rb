#!/usr/bin/env ruby
# frozen_string_literal: true

# Deep-dive on the 2 SOLUSDT holdout-confirmed finalists (1h+4h discovery,
# buckets: high_vol_range|4h_aligned=false short + trending_bear|4h_aligned=false
# long). Prints per-trade holdout breakdown by bucket, then sweeps
# stop_atr_buffer x forward_horizon_bars (r_target=3.0, delay=3 held fixed,
# matching what both winners share) on the SAME holdout slice to see how
# sensitive the result is to the exact grid point — a real edge should not
# require the *exact* winning cell.
#
# Usage:
#   ruby bin/inspect_sol_finalists.rb

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

CACHE_DIR = File.join(root, "data", "cache")
SYMBOL = "SOLUSDT"
BASE_KEY = "1h_365d"
BASE_MINUTES = 60
HTF_FACTOR = 4
HTF_LABEL = "4h"

def load_slice(cache_dir, symbol, base_key, slice_fn)
  raw_klines = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_klines_#{base_key}.json")))
  raw_funding = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_funding_365d.json")))
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  [slice_fn.call(candles), slice_fn.call(funding_series)]
end

def build_context(symbol, candles, funding)
  profile = SymbolProfile.for(symbol)
  htf_candles = CandleResampler.resample_candles(candles, HTF_FACTOR)
  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_htf = CandleResampler.align_higher_regimes(lower_candles: candles, higher_candles: htf_candles, higher_regimes: htf_regimes)
  regimes = RegimeClassifier.new(profile).classify(candles)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  closes = candles.map { |c| c[:close] }
  extractor = ContextFeatureExtractor.new(profile)
  extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
  extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)
  { profile: profile, regimes: regimes, swings: swings, extractor: extractor, aligned_htf: aligned_htf }
end

def bucket_key_for(event)
  htf = event.context.key?(:htf_aligned) ? event.context[:htf_aligned] : :unknown
  "#{event.context[:regime_state]}|#{HTF_LABEL}_aligned=#{htf}"
end

WINNING_BUCKETS = {
  "high_vol_range|4h_aligned=false" => "short",
  "trending_bear|4h_aligned=false" => "long"
}.freeze

def run_config(symbol, candles, funding, ctx, stop_buffer, horizon, delay, r_target, label)
  cost_model = TradeCostModel.new(fee_bps_per_side: 4.0, slippage_bps_per_side: 2.0, bar_interval_minutes: BASE_MINUTES)
  labeler = MoveLabeler.new(atr_period: 14, stop_atr_buffer: stop_buffer, r_multiple_target: r_target)
  events = labeler.label_signal_events(
    candles: candles, swings: ctx[:swings], regimes: ctx[:regimes], funding_series: funding,
    feature_extractor: ctx[:extractor], entry_delay_bars: delay, forward_horizon_bars: horizon,
    htf_regimes: ctx[:aligned_htf]
  )

  trades = events.filter_map do |event|
    bucket_key = bucket_key_for(event)
    expected_dir = WINNING_BUCKETS[bucket_key]
    next nil if expected_dir.nil? || expected_dir != event.direction.to_s

    net_r = cost_model.net_r_for_event(event: event, funding_series: funding)
    { bucket: bucket_key, direction: event.direction, entry_ts: event.entry_ts, net_r: net_r }
  end

  net_rs = trades.map { |t| t[:net_r] }
  mean_r = net_rs.empty? ? nil : net_rs.sum / net_rs.size.to_f
  win_rate = net_rs.empty? ? nil : net_rs.count(&:positive?) / net_rs.size.to_f
  puts format("%-28s stop=%.1f horizon=%-3d delay=%d r=%.1f  trades=%-4d mean_R=%-8s wr=%-6s",
              label, stop_buffer, horizon, delay, r_target, trades.size, mean_r&.round(3).inspect, win_rate&.round(3).inspect)
  [trades, mean_r]
end

puts "=" * 100
puts "PART 1 — per-trade holdout breakdown for the 2 confirmed finalists"
puts "=" * 100
holdout_candles, holdout_funding = load_slice(CACHE_DIR, SYMBOL, BASE_KEY, ->(s) { DataWindow.holdout_slice(s) })
holdout_ctx = build_context(SYMBOL, holdout_candles, holdout_funding)

[[1.0, 40, 3, "Finalist #1 (rank 1)"], [0.7, 20, 3, "Finalist #2 (rank 2)"]].each do |stop, horizon, delay, label|
  trades, = run_config(SYMBOL, holdout_candles, holdout_funding, holdout_ctx, stop, horizon, delay, 3.0, label)
  by_bucket = trades.group_by { |t| t[:bucket] }
  by_bucket.each do |bucket, ts|
    wr = ts.count { |t| t[:net_r].positive? } / ts.size.to_f
    mean_r = ts.sum { |t| t[:net_r] } / ts.size.to_f
    puts format("    %-45s n=%-3d mean_R=%+.3f wr=%.3f", bucket, ts.size, mean_r, wr)
  end
  puts "    Trade-by-trade:"
  trades.sort_by { |t| t[:entry_ts] }.each do |t|
    puts format("      %s  %-6s %-40s net_R=%+.3f", Time.at(t[:entry_ts]).utc.strftime("%Y-%m-%d %H:%M"), t[:direction], t[:bucket], t[:net_r])
  end
  puts
end

puts "=" * 100
puts "PART 2 — grid-neighborhood sensitivity on the SAME holdout (r_target=3.0, delay=3 fixed)"
puts "=" * 100
[0.7, 1.0, 1.5].each do |stop|
  [10, 20, 40].each do |horizon|
    run_config(SYMBOL, holdout_candles, holdout_funding, holdout_ctx, stop, horizon, 3, 3.0, "grid")
  end
end

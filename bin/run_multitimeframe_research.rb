#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/trade_cost_model"
require_relative "../lib/walk_forward_discovery_evaluator"
require_relative "../lib/candle_resampler"

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
TIMEFRAMES = {
  "15m" => 1,
  "30m" => 2,
  "1h" => 4,
  "2h" => 8,
  "4h" => 16
}.freeze
WALK_FORWARD_FOLDS = 6
EMBARGO_BARS = 20
FEE_BPS_PER_SIDE = 4.0
SLIPPAGE_BPS_PER_SIDE = 2.0
CACHE_DIR = File.join(root, "data", "cache")

def load_json(path)
  JSON.parse(File.read(path))
end

def top_buckets(result, limit: 5)
  Array(result.dig(:aggregate, :bucket_aggregates))
    .select { |bucket| bucket.trade_count.positive? && !bucket.alpha_net_r.nil? }
    .sort_by { |bucket| [-(bucket.alpha_net_r || -Float::INFINITY), -(bucket.net_expectancy_r || -Float::INFINITY)] }
    .first(limit)
end

def print_result(label, result)
  aggregate = result[:aggregate]
  if aggregate[:note]
    puts "#{label}: #{aggregate[:note]}"
    return
  end

  puts format("%-26s trades=%-4d net_r=%-8s alpha=%-8s win_rate=%-6s",
              label, aggregate[:total_trades], aggregate[:mean_net_expectancy_r].inspect,
              aggregate[:mean_alpha_net_r].inspect, aggregate[:mean_win_rate].inspect)
  top_buckets(result).each do |bucket|
    puts format("  %-40s dir=%-5s n=%-4d net_r=%-8s alpha=%-8s wr=%-6s",
                bucket.bucket_key, bucket.direction, bucket.trade_count,
                bucket.net_expectancy_r.inspect, bucket.alpha_net_r.inspect, bucket.win_rate.inspect)
  end
end

SYMBOLS.each do |symbol|
  raw_klines = load_json(File.join(CACHE_DIR, "#{symbol}_klines_15m_90d.json"))
  raw_funding = load_json(File.join(CACHE_DIR, "#{symbol}_funding_90d.json"))
  base_candles = BinanceDataLoader.klines_to_candles(raw_klines)
  base_funding = BinanceDataLoader.align_funding_series(base_candles, raw_funding)
  profile = SymbolProfile.for(symbol)

  puts "\n#{'=' * 90}"
  puts "#{symbol} multitimeframe research from cached 15m snapshot"
  puts "=" * 90

  TIMEFRAMES.each do |label, factor|
    candles = CandleResampler.resample_candles(base_candles, factor)
    funding_series = CandleResampler.resample_series(base_funding, factor)
    next if candles.size < 400

    minutes = 15 * factor
    horizon_bars = [[(300.0 / minutes).round, 5].max, 20].min
    cost_model = TradeCostModel.new(
      fee_bps_per_side: FEE_BPS_PER_SIDE,
      slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE,
      bar_interval_minutes: minutes
    )
    result = WalkForwardDiscoveryEvaluator.new(
      profile: profile,
      cost_model: cost_model,
      entry_delay_bars: 1,
      forward_horizon_bars: horizon_bars
    ).evaluate(
      candles: candles,
      funding_series: funding_series,
      n_folds: WALK_FORWARD_FOLDS,
      embargo_bars: EMBARGO_BARS
    )
    print_result("single_tf #{label}", result)
  end

  { "1h" => 4, "4h" => 16 }.each do |htf_label, factor|
    htf_candles = CandleResampler.resample_candles(base_candles, factor)
    htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
    aligned_htf_regimes = CandleResampler.align_higher_regimes(
      lower_candles: base_candles,
      higher_candles: htf_candles,
      higher_regimes: htf_regimes
    )
    cost_model = TradeCostModel.new(
      fee_bps_per_side: FEE_BPS_PER_SIDE,
      slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE,
      bar_interval_minutes: 15
    )
    result = WalkForwardDiscoveryEvaluator.new(
      profile: profile,
      cost_model: cost_model,
      entry_delay_bars: 1,
      forward_horizon_bars: 20,
      htf_regimes: aligned_htf_regimes,
      bucket_by: lambda { |ctx|
        htf = ctx.key?(:htf_aligned) ? ctx[:htf_aligned] : :unknown
        "#{ctx[:regime_state]}|#{htf_label}_aligned=#{htf}"
      }
    ).evaluate(
      candles: base_candles,
      funding_series: base_funding,
      n_folds: WALK_FORWARD_FOLDS,
      embargo_bars: EMBARGO_BARS
    )
    print_result("mtf 15m+#{htf_label}", result)
  end
end

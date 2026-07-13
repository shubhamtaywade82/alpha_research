# frozen_string_literal: true

require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/swing_point_detector"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/move_labeler"
require_relative "../lib/signature_analyzer"
require_relative "../lib/dynamic_risk_planner"

# Build synthetic price action, then encode it exactly as Binance's REST
# API actually returns it: kline prices as STRINGS, timestamps as integer
# milliseconds, funding entries as Hashes with string keys. This exercises
# the real parsing path in BinanceDataLoader, not an idealized shape.
def build_mock_binance_klines(n: 2000, seed_price: 150.0, interval_ms: 900_000)
  price = seed_price
  start_ms = (Time.now.to_f * 1000).to_i - n * interval_ms
  Array.new(n) do |i|
    drift = (i / 200).even? ? 0.15 : -0.1
    noise = (rand - 0.5) * 1.0
    price = [price + drift + noise, 1.0].max
    open_time = start_ms + i * interval_ms
    high = price + rand * 0.6
    low = [price - rand * 0.6, 0.1].max
    [
      open_time, format("%.4f", price - drift), format("%.4f", [high, price].max),
      format("%.4f", [low, price].min), format("%.4f", price), format("%.2f", rand(100..1000)),
      open_time + interval_ms - 1, "0", 100, "0", "0", "0"
    ]
  end
end

def build_mock_funding(klines, every_n: 32)
  klines.each_slice(every_n).filter_map do |slice|
    k = slice.first
    next if k.nil?

    { "symbol" => "SOLUSDT", "fundingTime" => k[0], "fundingRate" => format("%.6f", (rand - 0.5) * 0.001) }
  end
end

raw_klines = build_mock_binance_klines
raw_funding = build_mock_funding(raw_klines)
puts "Mock raw klines: #{raw_klines.size}, mock raw funding events: #{raw_funding.size}"
puts "Sample raw kline (Binance shape): #{raw_klines.first.inspect}"
puts "Sample raw funding (Binance shape): #{raw_funding.first.inspect}"

candles = BinanceDataLoader.klines_to_candles(raw_klines)
raise "candle parse count mismatch" unless candles.size == raw_klines.size
raise "candle fields not numeric" unless candles.first[:close].is_a?(Float)
puts "Parsed #{candles.size} candles OK. First: #{candles.first.inspect}"

funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
raise "funding series length mismatch" unless funding_series.size == candles.size
raise "funding series has nils" if funding_series.any?(&:nil?)
puts "Aligned funding series OK (#{funding_series.size} entries, e.g. #{funding_series.first(3)})"

profile = SymbolProfile.for("SOLUSDT")
regimes = RegimeClassifier.new(profile).classify(candles)
swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
puts "Regimes classified, #{swings.size} swings detected (#{swings.map(&:type).tally})"
raise "no swings detected on mock data" if swings.empty?

extractor = ContextFeatureExtractor.new(profile)
labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target)

baseline_samples = labeler.label_baseline_samples(
  candles: candles, regimes: regimes, funding_series: funding_series,
  feature_extractor: extractor, forward_horizon_bars: 20, stride: 5
)
puts "#{baseline_samples.size} baseline samples labeled"

errors = 0
[1, 3].each do |delay|
  events = labeler.label_signal_events(
    candles: candles, swings: swings, regimes: regimes, funding_series: funding_series,
    feature_extractor: extractor, entry_delay_bars: delay, forward_horizon_bars: 20
  )
  buckets = SignatureAnalyzer.analyze(swing_events: events, baseline_samples: baseline_samples)
  puts "delay=#{delay}: #{events.size} signal events -> #{buckets.size} buckets"
  buckets.each do |b|
    plan = DynamicRiskPlanner.plan(bucket_stats: b)
    puts "  #{b.bucket_key}: n=#{b.swing_count} edge=#{b.edge_over_baseline.inspect} tradeable=#{plan.tradeable}"
  end
rescue StandardError => e
  errors += 1
  puts "ERROR at delay=#{delay}: #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
end

puts "\n#{errors.zero? ? 'PASS' : 'FAIL'}: full real-data-shaped pipeline run with #{errors} errors"

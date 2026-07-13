# frozen_string_literal: true

require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/swing_point_detector"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/move_labeler"
require_relative "../lib/signature_analyzer"
require_relative "../lib/dynamic_risk_planner"

def build_synthetic_series(leg_count: 12, bars_per_leg: 60, seed_price: 150.0)
  price = seed_price
  ts = Time.now.to_i - leg_count * bars_per_leg * 900
  candles = []
  leg_count.times do |leg|
    trending = leg.even?
    drift = trending ? (leg % 4 == 0 ? 0.35 : -0.35) : 0.0
    bars_per_leg.times do
      noise = (rand - 0.5) * (trending ? 1.0 : 1.4)
      price = [price + drift + noise, 1.0].max
      high = price + rand * 0.7
      low = price - rand * 0.7
      ts += 900
      candles << { open: price - drift, high: [high, price].max, low: [low, price].min,
                    close: price, volume: rand(100..1000), ts: ts }
    end
  end
  candles
end

def run_scenario(label, candles, profile, regimes, funding_series, swings, extractor, labeler)
  events =
    case label
    when :inflated_retrospective
      labeler.label_swing_events(candles: candles, swings: swings, regimes: regimes,
                                  funding_series: funding_series, feature_extractor: extractor)
    when :delay_1
      labeler.label_signal_events(candles: candles, swings: swings, regimes: regimes,
                                   funding_series: funding_series, feature_extractor: extractor,
                                   entry_delay_bars: 1, forward_horizon_bars: 20)
    when :delay_3
      labeler.label_signal_events(candles: candles, swings: swings, regimes: regimes,
                                   funding_series: funding_series, feature_extractor: extractor,
                                   entry_delay_bars: 3, forward_horizon_bars: 20)
    end

  baseline_samples = labeler.label_baseline_samples(
    candles: candles, regimes: regimes, funding_series: funding_series,
    feature_extractor: extractor, forward_horizon_bars: 20, stride: 5
  )

  SignatureAnalyzer.analyze(swing_events: events, baseline_samples: baseline_samples)
end

[42, 7].each do |seed|
  srand(seed)
  puts "\n#{'=' * 60}"
  puts "SEED #{seed}"
  puts "=" * 60

  profile = SymbolProfile.for("SOLUSDT")
  candles = build_synthetic_series
  regimes = RegimeClassifier.new(profile).classify(candles)
  funding_series = Array.new(candles.size, 0.0001)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  extractor = ContextFeatureExtractor.new(profile)
  labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target)

  results = {}
  %i[inflated_retrospective delay_1 delay_3].each do |scenario|
    results[scenario] = run_scenario(scenario, candles, profile, regimes, funding_series, swings, extractor, labeler)
  end

  trending_states = %i[trending_bull trending_bear]

  puts "\n%-12s %-16s %6s %10s %10s %10s" % ["scenario", "regime", "n", "mean_r", "baseline_r", "edge"]
  results.each do |scenario, buckets|
    buckets.select { |b| trending_states.include?(b.bucket_key) }.each do |b|
      puts "%-12s %-16s %6d %10s %10s %10s" % [
        scenario, b.bucket_key, b.swing_count, b.swing_mean_r.inspect,
        b.baseline_mean_r.inspect, b.edge_over_baseline.inspect
      ]
    end
  end

  puts "\n-- Degradation check: does edge survive realistic entry delay? --"
  %i[trending_bull trending_bear].each do |regime|
    inflated = results[:inflated_retrospective].find { |b| b.bucket_key == regime }&.edge_over_baseline
    d1 = results[:delay_1].find { |b| b.bucket_key == regime }&.edge_over_baseline
    d3 = results[:delay_3].find { |b| b.bucket_key == regime }&.edge_over_baseline
    puts "#{regime}: inflated=#{inflated.inspect} -> delay_1=#{d1.inspect} -> delay_3=#{d3.inspect}"
  end
end

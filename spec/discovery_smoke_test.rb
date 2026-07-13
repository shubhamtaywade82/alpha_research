# frozen_string_literal: true

require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/swing_point_detector"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/move_labeler"
require_relative "../lib/signature_analyzer"
require_relative "../lib/dynamic_risk_planner"

# Builds a synthetic series with alternating trend legs (strong directional
# drift) and chop legs (pure noise, no drift) so we KNOW where the "real"
# tradeable structure is. If the pipeline is working, trending_bull/bear
# buckets should show clearly positive edge_over_baseline, while
# low_vol_range/high_vol_range buckets (sourced from the chop legs) should
# show close to zero edge. This is a test of the PIPELINE's correctness,
# not evidence of real-market alpha.
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

profile = SymbolProfile.for("SOLUSDT")
candles = build_synthetic_series
puts "Generated #{candles.size} synthetic candles"

regimes = RegimeClassifier.new(profile).classify(candles)
funding_series = Array.new(candles.size, 0.0001)

swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
puts "Detected #{swings.size} confirmed swings (types: #{swings.map(&:type).tally})"
raise "No swings detected — pipeline broken" if swings.empty?

extractor = ContextFeatureExtractor.new(profile)
labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target)

swing_events = labeler.label_swing_events(
  candles: candles, swings: swings, regimes: regimes,
  funding_series: funding_series, feature_extractor: extractor
)
puts "Labeled #{swing_events.size} swing events"

baseline_samples = labeler.label_baseline_samples(
  candles: candles, regimes: regimes, funding_series: funding_series,
  feature_extractor: extractor, forward_horizon_bars: 20, stride: 5
)
puts "Labeled #{baseline_samples.size} baseline samples"
raise "No swing events or baselines — pipeline broken" if swing_events.empty? || baseline_samples.empty?

buckets = SignatureAnalyzer.analyze(swing_events: swing_events, baseline_samples: baseline_samples)

puts "\n== Bucket analysis (regime_state) =="
buckets.each do |b|
  puts "#{b.bucket_key}: n=#{b.swing_count} swing_mean_r=#{b.swing_mean_r} " \
       "win_rate=#{b.swing_win_rate} baseline_mean_r=#{b.baseline_mean_r} " \
       "edge=#{b.edge_over_baseline} confidence=#{b.confidence}"

  plan = DynamicRiskPlanner.plan(bucket_stats: b)
  puts "  -> plan: tradeable=#{plan.tradeable} r_target=#{plan.r_multiple_target} " \
       "risk_pct=#{plan.risk_pct} reason=#{plan.reason}"
end

trending_buckets = buckets.select { |b| %i[trending_bull trending_bear].include?(b.bucket_key) }
range_buckets = buckets.select { |b| %i[high_vol_range low_vol_range].include?(b.bucket_key) }

trend_edge = trending_buckets.filter_map(&:edge_over_baseline)
range_edge = range_buckets.filter_map(&:edge_over_baseline)

puts "\n== Sanity check against planted structure =="
puts "Trending-regime edges: #{trend_edge}"
puts "Range-regime edges: #{range_edge}"

if trend_edge.any? && trend_edge.sum / trend_edge.size > (range_edge.any? ? range_edge.sum / range_edge.size : 0)
  puts "PASS: trending regimes show higher edge-over-baseline than range regimes, as planted."
else
  puts "FLAG: trending regimes did NOT show clearly higher edge than range regimes — " \
       "check regime classifier thresholds or synthetic data design."
end

# frozen_string_literal: true

# Converts a SignatureAnalyzer::BucketStats into an executable plan:
# whether the current context clears the bar to trade at all, what TP
# target to use (the bucket's own empirical mean R — dynamic, not a fixed
# constant), and a conservatively-scaled risk percentage. This deliberately
# does NOT implement full Kelly sizing — with only 3 symbols and small
# per-bucket sample sizes, full Kelly would be dangerously overconfident.
class DynamicRiskPlanner
  MIN_SAMPLE_SIZE = 30
  MIN_EDGE_OVER_BASELINE = 0.3 # R units; prior, not calibrated — sweep this

  Plan = Struct.new(:tradeable, :r_multiple_target, :risk_pct, :reason, keyword_init: true)

  def self.plan(bucket_stats:, base_risk_pct: 0.005, max_risk_pct: 0.015)
    if bucket_stats.nil? || bucket_stats.swing_count < MIN_SAMPLE_SIZE
      return Plan.new(
        tradeable: false, r_multiple_target: nil, risk_pct: 0.0,
        reason: "insufficient_sample n=#{bucket_stats&.swing_count || 0} (need #{MIN_SAMPLE_SIZE})"
      )
    end

    if bucket_stats.edge_over_baseline.nil? || bucket_stats.edge_over_baseline < MIN_EDGE_OVER_BASELINE
      return Plan.new(
        tradeable: false, r_multiple_target: nil, risk_pct: 0.0,
        reason: "no_edge_over_baseline edge=#{bucket_stats.edge_over_baseline.inspect}"
      )
    end

    confidence_scale = [[(bucket_stats.swing_count - MIN_SAMPLE_SIZE) / 100.0, 0.0].max, 1.0].min
    risk_pct = base_risk_pct + (max_risk_pct - base_risk_pct) * confidence_scale

    Plan.new(
      tradeable: true,
      r_multiple_target: bucket_stats.swing_mean_r,
      risk_pct: risk_pct.round(4),
      reason: "bucket=#{bucket_stats.bucket_key} n=#{bucket_stats.swing_count} " \
              "mean_r=#{bucket_stats.swing_mean_r} edge=#{bucket_stats.edge_over_baseline} " \
              "confidence=#{bucket_stats.confidence}"
    )
  end
end

# frozen_string_literal: true

# Compares swing-triggered outcomes against the unconditional baseline,
# bucketed (by default) by regime state. `edge_over_baseline` is the
# actual answer to "does this context signature predict anything beyond
# just being in that regime" — a bucket with edge_over_baseline <= 0 means
# the swing pattern has NOT beaten doing nothing special in that regime.
#
# NOTE: sample-size tiers below are NOT a formal significance test (no
# t-test/bootstrap). They are a coarse trust gate only. Do not present
# `confidence: :higher` as statistical proof — it means "more data went
# into this number," nothing more, until a proper test is added.
class SignatureAnalyzer
  BucketStats = Struct.new(
    :bucket_key, :swing_count, :swing_mean_r, :swing_win_rate,
    :baseline_count, :baseline_mean_r, :edge_over_baseline, :confidence,
    keyword_init: true
  )

  def self.analyze(swing_events:, baseline_samples:, bucket_by: ->(ctx) { ctx[:regime_state] })
    swing_buckets = swing_events.group_by { |e| bucket_by.call(e.context) }
    baseline_buckets = baseline_samples.group_by { |s| bucket_by.call(s.context) }
    keys = (swing_buckets.keys + baseline_buckets.keys).uniq

    keys.map do |key|
      swings = swing_buckets[key] || []
      baselines = baseline_buckets[key] || []

      swing_mean_r = mean(swings.map(&:r_multiple))
      swing_win_rate = swings.empty? ? nil : (swings.count { |e| e.r_multiple.positive? } / swings.size.to_f).round(3)

      baseline_mean_r =
        if baselines.empty? || swings.empty?
          nil
        else
          dominant_direction = swings.group_by(&:direction).max_by { |_, v| v.size }&.first
          vals = baselines.map { |b| dominant_direction == :short ? b.short_r_multiple : b.long_r_multiple }
          mean(vals)
        end

      edge = (swing_mean_r && baseline_mean_r) ? (swing_mean_r - baseline_mean_r).round(3) : nil

      BucketStats.new(
        bucket_key: key, swing_count: swings.size, swing_mean_r: swing_mean_r&.round(3),
        swing_win_rate: swing_win_rate, baseline_count: baselines.size,
        baseline_mean_r: baseline_mean_r&.round(3), edge_over_baseline: edge,
        confidence: confidence_tier(swings.size)
      )
    end
  end

  def self.mean(arr)
    return nil if arr.empty?

    arr.sum / arr.size.to_f
  end

  def self.confidence_tier(n)
    return :low if n < 30
    return :moderate if n < 100

    :higher
  end
end

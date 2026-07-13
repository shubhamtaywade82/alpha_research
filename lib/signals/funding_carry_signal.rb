# frozen_string_literal: true

# Funding-rate carry / crowding signal. This is architecturally independent
# of TrendFollowingSignal and SmcStructureSignal — it is a non-directional
# edge source (perp basis / funding skew), not a price-action signal, and
# must never be silently blended into directional confidence without
# being visible as its own line item.
#
# Logic: extreme positive funding implies longs are paying shorts heavily
# (crowded long positioning) -> mild mean-reversion bias short, and vice
# versa. This is a *bias*, not a standalone entry trigger — it's designed
# to be used as a confluence weight, or independently backtested as its
# own carry strategy family.
class FundingCarrySignal
  Result = Struct.new(:direction, :confidence, :funding_rate, :reason, keyword_init: true)
  NONE = Result.new(direction: :none, confidence: 0.0, funding_rate: nil, reason: "funding_not_extreme")

  def initialize(profile)
    @profile = profile
  end

  # funding_rate: current/most recent funding rate as a decimal (e.g. 0.0004)
  def evaluate(funding_rate:)
    return NONE if funding_rate.nil?

    threshold = @profile.funding_extreme_threshold
    magnitude = funding_rate.abs

    return NONE if magnitude < threshold

    confidence = [(magnitude - threshold) / threshold, 1.0].min

    if funding_rate.positive?
      Result.new(direction: :short, confidence: confidence, funding_rate: funding_rate,
                  reason: "crowded_long_funding=#{funding_rate.round(6)}")
    else
      Result.new(direction: :long, confidence: confidence, funding_rate: funding_rate,
                  reason: "crowded_short_funding=#{funding_rate.round(6)}")
    end
  end
end

# frozen_string_literal: true

# Combines TrendFollowingSignal + SmcStructureSignal into a single
# directional candidate via weighted confluence, with a hard conflict
# guard: if the two directional signals disagree, no candidate fires
# regardless of weights. FundingCarrySignal is reported alongside as an
# independent overlay (see class comment on FundingCarrySignal) — it can
# raise/lower the final score but can never flip direction on its own.
class ConfluenceScorer
  Candidate = Struct.new(
    :direction, :score, :trend_component, :structure_component,
    :funding_component, :reasons, keyword_init: true
  )
  NO_CANDIDATE = Candidate.new(
    direction: :none, score: 0.0, trend_component: 0.0,
    structure_component: 0.0, funding_component: 0.0, reasons: ["no_confluence"]
  )

  # Minimum combined score required to produce a candidate at all. This is
  # the probabilistic entry-quality gate standing in for "no closing in
  # negative PnL": high-probability entries only, structural stop still
  # applies downstream in the FSM/risk layer. This threshold is a prior,
  # not calibrated.
  MIN_SCORE_THRESHOLD = 0.55

  def initialize(profile, min_score_threshold: MIN_SCORE_THRESHOLD)
    @profile = profile
    @min_score_threshold = min_score_threshold
  end

  def score(trend:, structure:, funding:)
    return NO_CANDIDATE if trend.direction == :none && structure.direction == :none

    if directional_conflict?(trend, structure)
      return Candidate.new(
        direction: :none, score: 0.0, trend_component: 0.0,
        structure_component: 0.0, funding_component: 0.0,
        reasons: ["conflict_guard: trend=#{trend.direction} structure=#{structure.direction}"]
      )
    end

    direction = trend.direction != :none ? trend.direction : structure.direction

    trend_component = trend.direction == direction ? trend.confidence * @profile.weight_trend : 0.0
    structure_component = structure.direction == direction ? structure.confidence * @profile.weight_structure : 0.0

    funding_component =
      if funding.direction == direction
        funding.confidence * @profile.weight_funding_carry
      elsif funding.direction == :none
        0.0
      else
        # funding disagrees with direction -> penalize, don't cancel
        -funding.confidence * @profile.weight_funding_carry * 0.5
      end

    total = trend_component + structure_component + funding_component

    reasons = [trend.reason, structure.reason, funding.reason].reject { |r| r.include?("no_") }

    if total < @min_score_threshold
      Candidate.new(
        direction: :none, score: total, trend_component: trend_component,
        structure_component: structure_component, funding_component: funding_component,
        reasons: reasons + ["below_min_score_threshold=#{@min_score_threshold}"]
      )
    else
      Candidate.new(
        direction: direction, score: total, trend_component: trend_component,
        structure_component: structure_component, funding_component: funding_component,
        reasons: reasons
      )
    end
  end

  private

  def directional_conflict?(trend, structure)
    trend.direction != :none && structure.direction != :none && trend.direction != structure.direction
  end
end

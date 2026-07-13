# frozen_string_literal: true

require_relative "../indicators"

# Seykota-style trend continuation: only fires inside a confirmed trend
# regime (set by RegimeClassifier), using EMA fast/slow relationship plus
# ADX magnitude as a confidence proxy. This is a continuation signal, not
# a breakout-entry signal — it assumes the regime classifier already
# established directional context.
class TrendFollowingSignal
  Result = Struct.new(:direction, :confidence, :reason, keyword_init: true)
  NONE = Result.new(direction: :none, confidence: 0.0, reason: "no_trend_regime")

  def initialize(profile)
    @profile = profile
  end

  # regime: RegimeClassifier::Regime for this bar (may be nil)
  # candle: current bar
  # ema_fast_val / ema_slow_val: precomputed EMA values at this bar
  def evaluate(regime:, candle:, ema_fast_val:, ema_slow_val:)
    return NONE if regime.nil?

    case regime.state
    when :trending_bull
      return NONE unless candle[:close] > ema_fast_val

      Result.new(
        direction: :long,
        confidence: confidence_from_adx(regime.adx),
        reason: "trend_continuation_bull adx=#{regime.adx.round(1)}"
      )
    when :trending_bear
      return NONE unless candle[:close] < ema_fast_val

      Result.new(
        direction: :short,
        confidence: confidence_from_adx(regime.adx),
        reason: "trend_continuation_bear adx=#{regime.adx.round(1)}"
      )
    else
      NONE
    end
  end

  private

  # Maps ADX magnitude to a 0..1 confidence score. Thresholds are priors,
  # not calibrated — sweep during walk-forward validation.
  def confidence_from_adx(adx)
    floor = @profile.adx_trend_threshold
    ceiling = floor + 30.0
    [[(adx - floor) / (ceiling - floor), 0.0].max, 1.0].min
  end
end

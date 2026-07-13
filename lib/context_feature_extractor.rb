# frozen_string_literal: true

require_relative "indicators"

# Extracts the "what did the market look like right here" feature vector,
# using only data up to and including `index` — no lookahead. This is the
# context signature that gets compared across swing-point events and
# baseline samples in SignatureAnalyzer.
class ContextFeatureExtractor
  def initialize(profile)
    @profile = profile
  end

  # regime: RegimeClassifier::Regime for this index (nil if not warmed up)
  # htf_regime: optional higher-timeframe Regime aligned to this timestamp,
  #   for multi-timeframe confluence features
  # Returns nil (not a Hash) if inputs aren't sufficiently warmed up, so
  # callers can filter cleanly with `.compact`/`reject(&:nil?)`.
  def extract(candles:, index:, regime:, funding_rate:, htf_regime: nil)
    return nil if regime.nil? || index < 25

    closes = candles[0..index].map { |c| c[:close] }
    ema_fast = Indicators.ema(closes, @profile.ema_fast)[index]
    ema_slow = Indicators.ema(closes, @profile.ema_slow)[index]
    return nil if ema_fast.nil? || ema_slow.nil? || ema_fast.zero? || ema_slow.zero?

    close = candles[index][:close]
    vol_window = candles[[index - 20, 0].max..index].map { |c| c[:volume] }
    vol_mean = vol_window.sum / vol_window.size.to_f
    vol_std = Math.sqrt(vol_window.sum { |v| (v - vol_mean)**2 } / vol_window.size.to_f)
    vol_z = vol_std.zero? ? 0.0 : (candles[index][:volume] - vol_mean) / vol_std

    features = {
      regime_state: regime.state,
      adx: regime.adx.round(2),
      atr_percentile: regime.atr_percentile.round(3),
      bb_width: regime.bb_width.round(4),
      dist_from_ema_fast_pct: ((close - ema_fast) / ema_fast).round(4),
      dist_from_ema_slow_pct: ((close - ema_slow) / ema_slow).round(4),
      volume_zscore: vol_z.round(2),
      funding_rate: funding_rate&.round(6)
    }

    features[:htf_aligned] = htf_directional_match?(regime, htf_regime) unless htf_regime.nil?
    features
  end

  private

  def htf_directional_match?(regime, htf_regime)
    bullish = %i[trending_bull]
    bearish = %i[trending_bear]
    return true if regime.state == htf_regime.state
    (bullish.include?(regime.state) && bullish.include?(htf_regime.state)) ||
      (bearish.include?(regime.state) && bearish.include?(htf_regime.state))
  end
end

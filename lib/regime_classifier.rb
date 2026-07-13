# frozen_string_literal: true

require_relative "indicators"

# Classifies each bar into one of four regimes:
#   :trending_bull, :trending_bear, :high_vol_range, :low_vol_range
#
# This determines which signal families are even allowed to fire.
# Trend-following is gated to trending_* regimes; mean-reversion / carry
# is gated to range regimes. This separation is mandatory per your
# session/regime-separation principle.
class RegimeClassifier
  Regime = Struct.new(:state, :adx, :atr_percentile, :bb_width, keyword_init: true)

  def initialize(profile)
    @profile = profile
  end

  # Returns Array<Regime|nil>, same length as candles, nil where indicators
  # are not yet warmed up.
  def classify(candles)
    adx_series = Indicators.adx(candles, 14)
    atr_pct_series = Indicators.atr_percentile_rank(
      candles, atr_period: 14, lookback: @profile.atr_percentile_lookback
    )
    bb_series = Indicators.bb_width(candles, @profile.bb_width_lookback)
    ema_fast = Indicators.ema(candles.map { |c| c[:close] }, @profile.ema_fast)
    ema_slow = Indicators.ema(candles.map { |c| c[:close] }, @profile.ema_slow)

    candles.each_index.map do |i|
      adx = adx_series[i]
      atr_pct = atr_pct_series[i]
      bbw = bb_series[i]
      fast = ema_fast[i]
      slow = ema_slow[i]

      next nil if [adx, atr_pct, bbw, fast, slow].any?(&:nil?)

      state =
        if adx >= @profile.adx_trend_threshold && fast > slow
          :trending_bull
        elsif adx >= @profile.adx_trend_threshold && fast < slow
          :trending_bear
        elsif atr_pct >= 0.6
          :high_vol_range
        else
          :low_vol_range
        end

      Regime.new(state: state, adx: adx, atr_percentile: atr_pct, bb_width: bbw)
    end
  end
end

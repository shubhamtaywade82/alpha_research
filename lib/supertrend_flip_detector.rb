# frozen_string_literal: true

require_relative "swing_point_detector"

# Converts a SupertrendCalculator trend series into SwingPointDetector-
# compatible events (same SwingPoint struct), so every downstream class
# built for swing-based discovery (MoveLabeler, SignatureAnalyzer,
# WalkForwardDiscoveryEvaluator) works unchanged: a flip to uptrend is
# treated as a swing :low (-> long direction), a flip to downtrend as a
# swing :high (-> short direction). confirmed_index is the flip bar itself
# — a SuperTrend flip needs no retracement confirmation, unlike a ZigZag
# pivot, so it's "confirmed" the moment it happens.
module SupertrendFlipDetector
  module_function

  def detect(supertrend_series, candles)
    events = []
    prev_trend = nil

    supertrend_series.each_with_index do |bar, i|
      trend = bar[:trend]
      next if trend.nil?

      if !prev_trend.nil? && trend != prev_trend
        type = trend == 1 ? :low : :high
        events << SwingPointDetector::SwingPoint.new(
          index: i, ts: candles[i][:ts], price: candles[i][:close],
          type: type, confirmed_index: i
        )
      end
      prev_trend = trend
    end

    events
  end
end

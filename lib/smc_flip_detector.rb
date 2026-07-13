# frozen_string_literal: true

require_relative "swing_point_detector"
require_relative "signals/smc_structure_signal"

# Converts SmcStructureSignal's bar-by-bar direction (which can stay
# non-none across many consecutive bars while a sweep/BOS condition holds)
# into discrete SwingPointDetector-compatible flip events — one event per
# NEW direction, not one per bar. A :none bar (or a bar with the opposite
# direction) always breaks the streak, so a later recurrence of the same
# direction after a gap counts as a fresh signal.
module SmcFlipDetector
  module_function

  def detect(candles, profile)
    signal = SmcStructureSignal.new(profile)
    events = []
    prev_direction = :none

    candles.each_index do |i|
      result = signal.evaluate(candles: candles, index: i)
      if result.direction != :none && result.direction != prev_direction
        events << SwingPointDetector::SwingPoint.new(
          index: i, ts: candles[i][:ts], price: candles[i][:close],
          type: result.direction == :long ? :low : :high, confirmed_index: i
        )
      end
      prev_direction = result.direction
    end

    events
  end
end

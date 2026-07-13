# frozen_string_literal: true

require_relative "indicators"

# Classic ATR-relative ZigZag. A running extreme only becomes a *confirmed*
# swing once price retraces >= min_move_atr_multiple * ATR away from it —
# this mirrors how a swing would actually be confirmable in real time (you
# can't know bar i was THE high until price has moved away from it), so
# this same detector is safe to reuse live, not just for historical study.
#
# The final entry in the returned array may still be "in progress" from
# the algorithm's perspective (it's the current running extreme, not yet
# confirmed) — callers doing historical labeling should generally drop the
# last element unless they specifically want the live/unconfirmed extreme.
class SwingPointDetector
  SwingPoint = Struct.new(:index, :ts, :price, :type, :confirmed_index, keyword_init: true) # type: :high | :low

  def initialize(min_move_atr_multiple: 1.5, atr_period: 14)
    @min_move_atr_multiple = min_move_atr_multiple
    @atr_period = atr_period
  end

  # Returns Array<SwingPoint>, strictly alternating :high/:low, oldest -> newest.
  def detect(candles)
    return [] if candles.size < @atr_period + 2

    atr_series = Indicators.atr(candles, @atr_period)
    start_index = atr_series.index { |v| !v.nil? }
    return [] if start_index.nil?

    swings = []
    direction = nil
    extreme_index = start_index
    extreme_price = candles[start_index][:close]

    (start_index...candles.size).each do |i|
      atr = atr_series[i] || atr_series[extreme_index]
      next if atr.nil? || atr <= 0

      threshold = atr * @min_move_atr_multiple
      high = candles[i][:high]
      low = candles[i][:low]

      if direction.nil?
        if high - extreme_price >= threshold
          direction = :up
          extreme_index, extreme_price = i, high
        elsif extreme_price - low >= threshold
          direction = :down
          extreme_index, extreme_price = i, low
        elsif high > extreme_price
          extreme_index, extreme_price = i, high
        elsif low < extreme_price
          extreme_index, extreme_price = i, low
        end
        next
      end

      if direction == :up
        if high > extreme_price
          extreme_index, extreme_price = i, high
        elsif extreme_price - low >= threshold
          swings << SwingPoint.new(index: extreme_index, ts: candles[extreme_index][:ts],
                                    price: extreme_price, type: :high, confirmed_index: i)
          direction = :down
          extreme_index, extreme_price = i, low
        end
      else
        if low < extreme_price
          extreme_index, extreme_price = i, low
        elsif high - extreme_price >= threshold
          swings << SwingPoint.new(index: extreme_index, ts: candles[extreme_index][:ts],
                                    price: extreme_price, type: :low, confirmed_index: i)
          direction = :up
          extreme_index, extreme_price = i, high
        end
      end
    end

    swings
  end
end

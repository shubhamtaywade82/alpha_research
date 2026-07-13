# frozen_string_literal: true

# Builds higher timeframe candles from a lower timeframe series and aligns
# derived higher timeframe state back onto the lower timeframe timestamps.
module CandleResampler
  module_function

  def resample_candles(candles, factor)
    return candles if factor == 1

    candles.each_slice(factor).filter_map do |slice|
      next if slice.size < factor

      {
        ts: slice.last[:ts],
        open: slice.first[:open],
        high: slice.map { |c| c[:high] }.max,
        low: slice.map { |c| c[:low] }.min,
        close: slice.last[:close],
        volume: slice.sum { |c| c[:volume] }
      }
    end
  end

  def resample_series(series, factor)
    return series if factor == 1

    series.each_slice(factor).filter_map do |slice|
      next if slice.size < factor

      slice.last
    end
  end

  def align_higher_regimes(lower_candles:, higher_candles:, higher_regimes:)
    out = Array.new(lower_candles.size)
    hi = 0
    current = nil

    lower_candles.each_with_index do |candle, idx|
      while hi < higher_candles.size && higher_candles[hi][:ts] <= candle[:ts]
        current = higher_regimes[hi]
        hi += 1
      end
      out[idx] = current
    end

    out
  end
end

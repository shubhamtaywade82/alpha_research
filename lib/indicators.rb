# frozen_string_literal: true

# Candle = { open:, high:, low:, close:, volume:, ts: }
# All indicators take an Array<Candle> ordered oldest -> newest and return
# an Array of the same length, left-padded with nil where undefined.
module Indicators
  module_function

  def ema(values, period)
    return Array.new(values.size) if values.size < period

    k = 2.0 / (period + 1)
    out = Array.new(values.size)
    seed = values.first(period).sum / period.to_f
    out[period - 1] = seed
    (period...values.size).each do |i|
      prev = out[i - 1]
      out[i] = values[i] * k + prev * (1 - k)
    end
    out
  end

  def true_range(candles)
    candles.each_with_index.map do |c, i|
      prev_close = i.zero? ? c[:close] : candles[i - 1][:close]
      [
        c[:high] - c[:low],
        (c[:high] - prev_close).abs,
        (c[:low] - prev_close).abs
      ].max
    end
  end

  def atr(candles, period)
    tr = true_range(candles)
    wilder_smooth(tr, period)
  end

  # ATR as a percentile rank against its own trailing distribution.
  # Returns nil until lookback bars of ATR are available.
  def atr_percentile_rank(candles, atr_period:, lookback:)
    atr_series = atr(candles, atr_period)
    out = Array.new(candles.size)
    (0...candles.size).each do |i|
      next if atr_series[i].nil?

      window_start = [i - lookback + 1, 0].max
      window = atr_series[window_start..i].compact
      next if window.size < lookback

      current = atr_series[i]
      below = window.count { |v| v <= current }
      out[i] = below.to_f / window.size
    end
    out
  end

  def adx(candles, period)
    return Array.new(candles.size) if candles.size < period + 1

    plus_dm = Array.new(candles.size, 0.0)
    minus_dm = Array.new(candles.size, 0.0)
    (1...candles.size).each do |i|
      up_move = candles[i][:high] - candles[i - 1][:high]
      down_move = candles[i - 1][:low] - candles[i][:low]
      plus_dm[i] = (up_move > down_move && up_move.positive?) ? up_move : 0.0
      minus_dm[i] = (down_move > up_move && down_move.positive?) ? down_move : 0.0
    end

    tr = true_range(candles)
    smoothed_tr = wilder_smooth(tr, period)
    smoothed_plus_dm = wilder_smooth(plus_dm, period)
    smoothed_minus_dm = wilder_smooth(minus_dm, period)

    di_plus = Array.new(candles.size)
    di_minus = Array.new(candles.size)
    dx = Array.new(candles.size)

    (0...candles.size).each do |i|
      next if smoothed_tr[i].nil? || smoothed_tr[i].zero?

      di_plus[i] = 100.0 * smoothed_plus_dm[i] / smoothed_tr[i]
      di_minus[i] = 100.0 * smoothed_minus_dm[i] / smoothed_tr[i]
      denom = di_plus[i] + di_minus[i]
      dx[i] = denom.zero? ? 0.0 : 100.0 * (di_plus[i] - di_minus[i]).abs / denom
    end

    wilder_smooth(dx, period)
  end

  # Bollinger Band width, normalized by the middle band (percent width).
  def bb_width(candles, period, num_std: 2.0)
    closes = candles.map { |c| c[:close] }
    out = Array.new(candles.size)
    (period - 1...candles.size).each do |i|
      window = closes[(i - period + 1)..i]
      mean = window.sum / period.to_f
      variance = window.sum { |v| (v - mean)**2 } / period.to_f
      std = Math.sqrt(variance)
      next if mean.zero?

      upper = mean + num_std * std
      lower = mean - num_std * std
      out[i] = (upper - lower) / mean
    end
    out
  end

  # Robust to leading nils in `series` (e.g. dx values are nil until the
  # upstream smoothed TR/DM warm up). Finds the first run of `period`
  # consecutive non-nil values to seed the smoother, then carries forward
  # the prior smoothed value on any subsequent nil rather than raising.
  def wilder_smooth(series, period)
    out = Array.new(series.size)
    start_index = series.index { |v| !v.nil? }
    return out if start_index.nil? || series.size - start_index < period

    window = series[start_index, period]
    return out if window.any?(&:nil?)

    out[start_index + period - 1] = window.sum / period.to_f

    ((start_index + period)...series.size).each do |i|
      prev = out[i - 1]
      val = series[i]
      out[i] = val.nil? || prev.nil? ? prev : (prev * (period - 1) + val) / period.to_f
    end
    out
  end
end

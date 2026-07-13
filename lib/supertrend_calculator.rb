# frozen_string_literal: true

require_relative "indicators"

# Three adaptive SuperTrend variants, each returning Array<{trend:, value:}>
# (trend: 1 = uptrend, -1 = downtrend, nil during warmup), same length as
# candles. All are causal (no lookahead) — every bar's trend/value/multiplier
# uses only data up to and including that bar.
module SupertrendCalculator
  module_function

  # Classic SuperTrend recursion shared by all variants, parameterized by a
  # per-bar multiplier series (constant for the plain variant, dynamic for
  # the adaptive ones) and a per-bar ATR series.
  def build(candles, atr_series:, multiplier_series:)
    n = candles.size
    trend = Array.new(n)
    value = Array.new(n)
    final_upper = Array.new(n)
    final_lower = Array.new(n)

    (0...n).each do |i|
      atr = atr_series[i]
      mult = multiplier_series[i]
      next if atr.nil? || mult.nil?

      hl2 = (candles[i][:high] + candles[i][:low]) / 2.0
      basic_upper = hl2 + mult * atr
      basic_lower = hl2 - mult * atr

      prev_final_upper = i.positive? ? final_upper[i - 1] : nil
      prev_final_lower = i.positive? ? final_lower[i - 1] : nil
      prev_close = i.positive? ? candles[i - 1][:close] : nil

      final_upper[i] = if prev_final_upper.nil? || basic_upper < prev_final_upper || (prev_close && prev_close > prev_final_upper)
                         basic_upper
                       else
                         prev_final_upper
                       end
      final_lower[i] = if prev_final_lower.nil? || basic_lower > prev_final_lower || (prev_close && prev_close < prev_final_lower)
                         basic_lower
                       else
                         prev_final_lower
                       end

      prev_trend = i.positive? ? trend[i - 1] : nil
      trend[i] = if prev_trend.nil?
                   candles[i][:close] >= final_lower[i] ? 1 : -1
                 elsif prev_trend == 1
                   candles[i][:close] < final_lower[i] ? -1 : 1
                 else
                   candles[i][:close] > final_upper[i] ? 1 : -1
                 end
      value[i] = trend[i] == 1 ? final_lower[i] : final_upper[i]
    end

    (0...n).map { |i| { trend: trend[i], value: value[i] } }
  end

  # Variant 1: multiplier scales linearly with the ATR's own percentile rank
  # over its trailing distribution — low relative volatility -> tight band
  # (fast flips), high relative volatility -> wide band (fewer whipsaws).
  def percentile_scaled(candles, atr_period:, min_mult:, max_mult:, pct_lookback: 100)
    atr_series = Indicators.atr(candles, atr_period)
    pct_rank = Indicators.atr_percentile_rank(candles, atr_period: atr_period, lookback: pct_lookback)
    multiplier_series = pct_rank.map { |p| p.nil? ? nil : min_mult + (max_mult - min_mult) * p }
    build(candles, atr_series: atr_series, multiplier_series: multiplier_series)
  end

  # Variant 2: 1D k-means (k=3) over a trailing window of ATR values,
  # assigning each bar's ATR to a low/medium/high volatility cluster, each
  # with its own fixed multiplier. Deterministic init (quantile-based, not
  # random) so results are reproducible bar-to-bar and run-to-run.
  def kmeans_clustered(candles, atr_period:, cluster_lookback: 100, mult_low:, mult_mid:, mult_high:)
    atr_series = Indicators.atr(candles, atr_period)
    n = candles.size
    multiplier_series = Array.new(n)

    (0...n).each do |i|
      next if atr_series[i].nil?

      window_start = [i - cluster_lookback + 1, 0].max
      window = atr_series[window_start..i].compact
      next if window.size < [cluster_lookback / 2, 10].max

      centroids = kmeans_1d(window, k: 3)
      current = atr_series[i]
      cluster = centroids.each_index.min_by { |c| (centroids[c] - current).abs }
      multiplier_series[i] = [mult_low, mult_mid, mult_high][cluster]
    end

    build(candles, atr_series: atr_series, multiplier_series: multiplier_series)
  end

  # Variant 3: "completely adaptive" — BOTH the ATR lookback period and the
  # multiplier respond to market conditions each bar. Period narrows in
  # efficient/trending conditions (Kaufman efficiency ratio -> 1, faster
  # reaction) and widens in choppy conditions (efficiency ratio -> 0, more
  # smoothing); multiplier still scales with ATR percentile rank as in
  # variant 1. Uses a simple rolling-mean TR average (not Wilder recursion)
  # since Wilder smoothing isn't well-defined over a bar-varying window.
  def fully_adaptive(candles, base_period:, min_period:, max_period:, min_mult:, max_mult:, er_lookback: 10, pct_lookback: 100)
    tr = Indicators.true_range(candles)
    closes = candles.map { |c| c[:close] }
    n = candles.size

    efficiency_ratio = Array.new(n)
    (er_lookback...n).each do |i|
      net_change = (closes[i] - closes[i - er_lookback]).abs
      path_sum = 0.0
      ((i - er_lookback + 1)..i).each { |j| path_sum += (closes[j] - closes[j - 1]).abs }
      efficiency_ratio[i] = path_sum.zero? ? 0.0 : net_change / path_sum
    end

    dynamic_period = Array.new(n)
    (0...n).each do |i|
      er = efficiency_ratio[i]
      next if er.nil?

      period = base_period * (2.0 - er)
      dynamic_period[i] = period.round.clamp(min_period, max_period)
    end

    dynamic_atr = Array.new(n)
    (0...n).each do |i|
      period = dynamic_period[i]
      next if period.nil? || i < period - 1

      window = tr[(i - period + 1)..i]
      dynamic_atr[i] = window.sum / period.to_f
    end

    # Percentile rank of the dynamic ATR against its own trailing distribution.
    pct_rank = Array.new(n)
    (0...n).each do |i|
      next if dynamic_atr[i].nil?

      window_start = [i - pct_lookback + 1, 0].max
      window = dynamic_atr[window_start..i].compact
      next if window.size < pct_lookback

      current = dynamic_atr[i]
      pct_rank[i] = window.count { |v| v <= current }.to_f / window.size
    end

    multiplier_series = pct_rank.map { |p| p.nil? ? nil : min_mult + (max_mult - min_mult) * p }
    build(candles, atr_series: dynamic_atr, multiplier_series: multiplier_series)
  end

  # Deterministic 1D k-means: seed centroids from evenly-spaced quantiles of
  # the sorted window (not random), then run Lloyd's algorithm to convergence
  # or a small fixed iteration cap.
  def kmeans_1d(values, k:, max_iterations: 10)
    sorted = values.sort
    centroids = Array.new(k) { |c| sorted[((c + 0.5) / k * (sorted.size - 1)).round] }

    max_iterations.times do
      groups = Array.new(k) { [] }
      values.each do |v|
        nearest = centroids.each_index.min_by { |c| (centroids[c] - v).abs }
        groups[nearest] << v
      end
      new_centroids = groups.each_with_index.map { |g, c| g.empty? ? centroids[c] : g.sum / g.size.to_f }
      break if new_centroids == centroids

      centroids = new_centroids
    end

    centroids.sort
  end
end

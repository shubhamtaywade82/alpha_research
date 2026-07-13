# frozen_string_literal: true

require_relative "indicators"

# Two labeling jobs, deliberately kept separate:
#
# 1. label_swing_events: the "reverse-engineered pattern" — from each
#    confirmed swing to the next opposite swing, what context preceded it
#    and what R-multiple was realized (using the swing's own ATR-based
#    stop distance).
#
# 2. label_baseline_samples: an UNCONDITIONAL control — at ordinary,
#    non-swing bars (sampled on a stride to keep volume sane), what R-
#    multiple would a same-direction trade have realized over a FIXED
#    forward horizon, using the same stop-distance convention. This is
#    the number swing-triggered events must beat, in the same regime
#    bucket, or the "pattern" isn't adding anything over just being in
#    that regime.
#
# KNOWN SIMPLIFICATION: both labelers use max-favorable-excursion to the
# endpoint (swing-to-swing, or end of forward window) — neither checks
# whether the stop would have been hit FIRST. This is not a substitute
# for proper triple-barrier sequencing; treat R-multiples here as an
# upper-bound signal for discovery, not a realistic P&L simulation.
class MoveLabeler
  SwingEvent = Struct.new(
    :direction, :entry_index, :entry_ts, :entry_price, :stop_price,
    :exit_index, :exit_price, :r_multiple, :context, keyword_init: true
  )
  BaselineSample = Struct.new(
    :index, :ts, :context, :long_r_multiple, :short_r_multiple, keyword_init: true
  )

  def initialize(atr_period: 14, stop_atr_buffer: 0.5)
    @atr_period = atr_period
    @stop_atr_buffer = stop_atr_buffer
  end

  def label_swing_events(candles:, swings:, regimes:, funding_series:, feature_extractor:)
    atr_series = Indicators.atr(candles, @atr_period)
    events = []

    swings.each_cons(2) do |a, b|
      next if a.type == b.type # should already alternate; guard anyway

      direction = a.type == :low ? :long : :short
      entry_price = a.price
      atr_at_entry = atr_series[a.index]
      next if atr_at_entry.nil? || atr_at_entry <= 0

      stop_price = direction == :long ? entry_price - atr_at_entry * @stop_atr_buffer \
                                       : entry_price + atr_at_entry * @stop_atr_buffer
      stop_distance = (entry_price - stop_price).abs
      next if stop_distance <= 0

      exit_price = b.price
      raw_move = direction == :long ? exit_price - entry_price : entry_price - exit_price
      r_multiple = raw_move / stop_distance

      context = feature_extractor.extract(
        candles: candles, index: a.index, regime: regimes[a.index], funding_rate: funding_series[a.index]
      )
      next if context.nil?

      events << SwingEvent.new(
        direction: direction, entry_index: a.index, entry_ts: a.ts, entry_price: entry_price,
        stop_price: stop_price, exit_index: b.index, exit_price: exit_price,
        r_multiple: r_multiple.round(3), context: context
      )
    end

    events
  end

  # REALISTIC variant, unlike label_swing_events above: entry happens
  # `entry_delay_bars` AFTER the swing was actually confirmed (not at the
  # extreme itself, which is only knowable in hindsight), and the outcome
  # is measured the same way the baseline measures it — fixed forward
  # horizon, max-favorable-excursion within that window. This makes
  # signal-triggered events and baseline samples directly comparable:
  # same entry-to-outcome methodology on both sides, only the trigger
  # condition (just-confirmed swing vs. an ordinary bar) differs.
  def label_signal_events(candles:, swings:, regimes:, funding_series:, feature_extractor:,
                           entry_delay_bars:, forward_horizon_bars: 20)
    atr_series = Indicators.atr(candles, @atr_period)
    events = []

    swings.each do |swing|
      entry_index = swing.confirmed_index + entry_delay_bars
      next if entry_index <= swing.confirmed_index - 1 # guard
      next if entry_index + forward_horizon_bars >= candles.size

      direction = swing.type == :low ? :long : :short
      atr_at_entry = atr_series[entry_index]
      next if atr_at_entry.nil? || atr_at_entry <= 0

      entry_price = candles[entry_index][:close]
      stop_price = direction == :long ? entry_price - atr_at_entry * @stop_atr_buffer \
                                       : entry_price + atr_at_entry * @stop_atr_buffer
      stop_distance = (entry_price - stop_price).abs
      next if stop_distance <= 0

      future = candles[(entry_index + 1)..(entry_index + forward_horizon_bars)]
      max_high = future.map { |c| c[:high] }.max
      min_low = future.map { |c| c[:low] }.min
      raw_move = direction == :long ? (max_high - entry_price) : (entry_price - min_low)
      exit_price = direction == :long ? max_high : min_low

      regime = regimes[entry_index]
      context = feature_extractor.extract(
        candles: candles, index: entry_index, regime: regime, funding_rate: funding_series[entry_index]
      )
      next if context.nil?

      events << SwingEvent.new(
        direction: direction, entry_index: entry_index, entry_ts: candles[entry_index][:ts],
        entry_price: entry_price, stop_price: stop_price, exit_index: entry_index + forward_horizon_bars,
        exit_price: exit_price, r_multiple: (raw_move / stop_distance).round(3), context: context
      )
    end

    events
  end

  def label_baseline_samples(candles:, regimes:, funding_series:, feature_extractor:,
                              forward_horizon_bars: 20, stride: 5)
    atr_series = Indicators.atr(candles, @atr_period)
    samples = []

    (0...candles.size).step(stride) do |i|
      next if i + forward_horizon_bars >= candles.size

      regime = regimes[i]
      atr = atr_series[i]
      next if regime.nil? || atr.nil? || atr <= 0

      entry_price = candles[i][:close]
      stop_distance = atr * @stop_atr_buffer
      future = candles[(i + 1)..(i + forward_horizon_bars)]
      max_high = future.map { |c| c[:high] }.max
      min_low = future.map { |c| c[:low] }.min

      context = feature_extractor.extract(
        candles: candles, index: i, regime: regime, funding_rate: funding_series[i]
      )
      next if context.nil?

      samples << BaselineSample.new(
        index: i, ts: candles[i][:ts], context: context,
        long_r_multiple: ((max_high - entry_price) / stop_distance).round(3),
        short_r_multiple: ((entry_price - min_low) / stop_distance).round(3)
      )
    end

    samples
  end
end

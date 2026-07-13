# frozen_string_literal: true

require_relative "indicators"

# Three labeling jobs, deliberately kept separate:
#
# 1. label_swing_events: from each confirmed swing to the next opposite
#    swing, what context preceded it and what R-multiple was realized
#    (using first-touch stop/target simulation, not MFE).
#
# 2. label_signal_events: entry happens after swing confirmation with a
#    delay, outcome determined by first-touch of ATR-based stop or
#    R-multiple target within a fixed forward horizon. This mirrors
#    realistic trade management.
#
# 3. label_baseline_samples: an UNCONDITIONAL control — at ordinary,
#    non-swing bars (sampled on a stride), what R-multiple would a
#    same-direction trade have realized over a FIXED forward horizon
#    using the same first-touch logic. This is the number swing-triggered
#    events must beat, in the same regime bucket, or the "pattern" isn't
#    adding anything over just being in that regime.
class MoveLabeler
  SwingEvent = Struct.new(
    :direction, :entry_index, :entry_ts, :entry_price, :stop_price,
    :exit_index, :exit_price, :r_multiple, :context, keyword_init: true
  )
  BaselineSample = Struct.new(
    :index, :ts, :entry_price, :stop_distance, :context,
    :long_exit_index, :short_exit_index, :long_r_multiple, :short_r_multiple,
    keyword_init: true
  )

  def initialize(atr_period: 14, stop_atr_buffer: 0.5, r_multiple_target:, atr_cache: nil)
    @atr_period = atr_period
    @stop_atr_buffer = stop_atr_buffer
    @r_multiple_target = r_multiple_target
    @atr_cache = atr_cache
  end

  attr_writer :atr_cache

  def label_swing_events(candles:, swings:, regimes:, funding_series:, feature_extractor:)
    atr_series = @atr_cache || Indicators.atr(candles, @atr_period)
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

      target_price = direction == :long ? entry_price + stop_distance * @r_multiple_target \
                                         : entry_price - stop_distance * @r_multiple_target

      exit_index = nil
      exit_price = nil
      r_multiple = nil

      (a.index + 1..b.index).each do |i|
        bar = candles[i]
        if direction == :long
          if bar[:low] <= stop_price
            exit_index, exit_price, r_multiple = i, stop_price, -1.0
            break
          elsif bar[:high] >= target_price
            exit_index, exit_price, r_multiple = i, target_price, @r_multiple_target
            break
          end
        else
          if bar[:high] >= stop_price
            exit_index, exit_price, r_multiple = i, stop_price, -1.0
            break
          elsif bar[:low] <= target_price
            exit_index, exit_price, r_multiple = i, target_price, @r_multiple_target
            break
          end
        end
      end

      unless exit_index
        exit_index = b.index
        exit_price = b.price
        raw_move = direction == :long ? exit_price - entry_price : entry_price - exit_price
        r_multiple = raw_move / stop_distance
      end

      context = feature_extractor.extract(
        candles: candles, index: a.index, regime: regimes[a.index], funding_rate: funding_series[a.index]
      )
      next if context.nil?

      events << SwingEvent.new(
        direction: direction, entry_index: a.index, entry_ts: a.ts, entry_price: entry_price,
        stop_price: stop_price, exit_index: exit_index, exit_price: exit_price,
        r_multiple: r_multiple.round(3), context: context
      )
    end

    events
  end

  # Signal-triggered events: entry happens `entry_delay_bars` AFTER the
  # swing was confirmed (not at the extreme itself), and the outcome is
  # determined by first-touch of the ATR-based stop or R-multiple target.
  # If neither is touched within the forward horizon, exit at the final bar's
  # close. This matches how a real trade would be managed, avoiding the
  # optimistic MFE bias of the previous implementation.
  def label_signal_events(candles:, swings:, regimes:, funding_series:, feature_extractor:,
                           entry_delay_bars:, forward_horizon_bars: 20, htf_regimes: nil)
    atr_series = @atr_cache || Indicators.atr(candles, @atr_period)
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

      target_price = direction == :long ? entry_price + stop_distance * @r_multiple_target \
                                         : entry_price - stop_distance * @r_multiple_target

      exit_index = nil
      exit_price = nil
      r_multiple = nil
      last_bar = entry_index + forward_horizon_bars

      ((entry_index + 1)..last_bar).each do |i|
        bar = candles[i]
        if direction == :long
          if bar[:low] <= stop_price
            exit_index, exit_price, r_multiple = i, stop_price, -1.0
            break
          elsif bar[:high] >= target_price
            exit_index, exit_price, r_multiple = i, target_price, @r_multiple_target
            break
          end
        else
          if bar[:high] >= stop_price
            exit_index, exit_price, r_multiple = i, stop_price, -1.0
            break
          elsif bar[:low] <= target_price
            exit_index, exit_price, r_multiple = i, target_price, @r_multiple_target
            break
          end
        end
      end

      unless exit_index
        exit_index = last_bar
        exit_price = candles[last_bar][:close]
        raw_move = direction == :long ? exit_price - entry_price : entry_price - exit_price
        r_multiple = raw_move / stop_distance
      end

      regime = regimes[entry_index]
      htf_regime = htf_regimes ? htf_regimes[entry_index] : nil
      context = feature_extractor.extract(
        candles: candles, index: entry_index, regime: regime, funding_rate: funding_series[entry_index],
        htf_regime: htf_regime
      )
      next if context.nil?

      events << SwingEvent.new(
        direction: direction, entry_index: entry_index, entry_ts: candles[entry_index][:ts],
        entry_price: entry_price, stop_price: stop_price, exit_index: exit_index,
        exit_price: exit_price, r_multiple: r_multiple.round(3), context: context
      )
    end

    events
  end

  def label_baseline_samples(candles:, regimes:, funding_series:, feature_extractor:,
                              forward_horizon_bars: 20, stride: 5, htf_regimes: nil)
    atr_series = @atr_cache || Indicators.atr(candles, @atr_period)
    samples = []

    (0...candles.size).step(stride) do |i|
      next if i + forward_horizon_bars >= candles.size

      regime = regimes[i]
      atr = atr_series[i]
      next if regime.nil? || atr.nil? || atr <= 0

      entry_price = candles[i][:close]
      stop_distance = atr * @stop_atr_buffer
      next if stop_distance <= 0

      stop_long = entry_price - stop_distance
      target_long = entry_price + stop_distance * @r_multiple_target
      stop_short = entry_price + stop_distance
      target_short = entry_price - stop_distance * @r_multiple_target

      long_r = nil
      short_r = nil
      long_exit_index = nil
      short_exit_index = nil
      last_bar = i + forward_horizon_bars

      ((i + 1)..last_bar).each do |j|
        bar = candles[j]
        if long_r.nil?
          if bar[:low] <= stop_long
            long_r = -1.0
            long_exit_index = j
          elsif bar[:high] >= target_long
            long_r = @r_multiple_target
            long_exit_index = j
          end
        end
        if short_r.nil?
          if bar[:high] >= stop_short
            short_r = -1.0
            short_exit_index = j
          elsif bar[:low] <= target_short
            short_r = @r_multiple_target
            short_exit_index = j
          end
        end
        break if !long_r.nil? && !short_r.nil?
      end

      if long_r.nil?
        close_price = candles[last_bar][:close]
        long_r = (close_price - entry_price) / stop_distance
        long_exit_index = last_bar
      end
      if short_r.nil?
        close_price = candles[last_bar][:close]
        short_r = (entry_price - close_price) / stop_distance
        short_exit_index = last_bar
      end

      htf_regime = htf_regimes ? htf_regimes[i] : nil
      context = feature_extractor.extract(
        candles: candles, index: i, regime: regime, funding_rate: funding_series[i],
        htf_regime: htf_regime
      )
      next if context.nil?

      samples << BaselineSample.new(
        index: i, ts: candles[i][:ts], entry_price: entry_price,
        stop_distance: stop_distance, context: context,
        long_exit_index: long_exit_index,
        short_exit_index: short_exit_index,
        long_r_multiple: long_r.round(3),
        short_r_multiple: short_r.round(3)
      )
    end

    samples
  end
end

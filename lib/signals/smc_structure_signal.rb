# frozen_string_literal: true

# Simplified Smart Money Concepts structure signal:
#   1. Tracks rolling swing highs/lows over `structure_lookback` bars.
#   2. Detects a liquidity sweep: a wick pierces the prior swing extreme
#      but the candle closes back inside the prior range (stop hunt).
#   3. Detects break-of-structure: a close beyond the prior swing extreme,
#      confirming continuation rather than a sweep/trap.
#
# This is a deliberately simplified proxy for full SMC-CE v5 — it captures
# the sweep-vs-BOS distinction that mattered in your SOL/USDT analysis
# (short-TF bullish action inside a bearish HTF context = trap, not
# reversal) without claiming parity with the full indicator.
class SmcStructureSignal
  Result = Struct.new(:direction, :confidence, :reason, keyword_init: true)
  NONE = Result.new(direction: :none, confidence: 0.0, reason: "no_structure_signal")

  def initialize(profile)
    @profile = profile
  end

  # candles: full array up to and including current bar (oldest -> newest)
  # index: index of the current/latest bar to evaluate
  def evaluate(candles:, index:)
    lookback = @profile.structure_lookback
    return NONE if index < lookback

    window = candles[(index - lookback)...index] # prior bars, excludes current
    swing_high = window.map { |c| c[:high] }.max
    swing_low = window.map { |c| c[:low] }.min
    current = candles[index]

    if current[:high] > swing_high && current[:close] < swing_high
      # Wick swept liquidity above prior high, closed back below -> bearish trap
      Result.new(direction: :short, confidence: 0.6, reason: "liquidity_sweep_high")
    elsif current[:low] < swing_low && current[:close] > swing_low
      # Wick swept liquidity below prior low, closed back above -> bullish trap
      Result.new(direction: :long, confidence: 0.6, reason: "liquidity_sweep_low")
    elsif current[:close] > swing_high
      Result.new(direction: :long, confidence: 0.7, reason: "break_of_structure_up")
    elsif current[:close] < swing_low
      Result.new(direction: :short, confidence: 0.7, reason: "break_of_structure_down")
    else
      NONE
    end
  end
end

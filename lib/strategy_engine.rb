# frozen_string_literal: true

require_relative "symbol_profile"
require_relative "indicators"
require_relative "regime_classifier"
require_relative "signals/trend_following_signal"
require_relative "signals/smc_structure_signal"
require_relative "signals/funding_carry_signal"
require_relative "confluence_scorer"
require_relative "position_sizer"

# Orchestrates one symbol's full evaluation pipeline for a single bar index.
# This is deliberately a plain Ruby object (no ActiveRecord/service-object
# ceremony) — orchestration only, domain logic lives in the signal/scorer
# classes above.
class StrategyEngine
  Evaluation = Struct.new(:symbol, :timestamp, :regime, :candidate, :sizing, keyword_init: true)

  def initialize(symbol)
    @symbol = symbol
    @profile = SymbolProfile.for(symbol)
    @regime_classifier = RegimeClassifier.new(@profile)
    @trend_signal = TrendFollowingSignal.new(@profile)
    @structure_signal = SmcStructureSignal.new(@profile)
    @funding_signal = FundingCarrySignal.new(@profile)
    @scorer = ConfluenceScorer.new(@profile)
    @sizer = PositionSizer.new(@profile)
  end

  # candles: Array<Candle>, oldest -> newest, up to and including `index`
  # index: bar to evaluate (must have enough history for warmup)
  # funding_rate: latest funding rate at this bar (nil if unavailable)
  # account_equity: for sizing, only relevant if a candidate fires
  def evaluate(candles:, index:, funding_rate:, account_equity: nil, risk_pct: 0.01)
    regimes = @regime_classifier.classify(candles[0..index])
    regime = regimes[index]

    ema_fast_series = Indicators.ema(candles[0..index].map { |c| c[:close] }, @profile.ema_fast)
    candle = candles[index]

    trend = @trend_signal.evaluate(
      regime: regime, candle: candle, ema_fast_val: ema_fast_series[index],
      ema_slow_val: nil # slow EMA already folded into regime.state
    )
    structure = @structure_signal.evaluate(candles: candles[0..index], index: index)
    funding = @funding_signal.evaluate(funding_rate: funding_rate)

    candidate = @scorer.score(trend: trend, structure: structure, funding: funding)

    sizing = nil
    if candidate.direction != :none && account_equity
      stop_price = structural_stop(candles: candles[0..index], index: index, direction: candidate.direction)
      sizing = @sizer.size(
        account_equity: account_equity, entry_price: candle[:close],
        stop_price: stop_price, risk_pct: risk_pct, direction: candidate.direction
      )
    end

    Evaluation.new(symbol: @symbol, timestamp: candle[:ts], regime: regime, candidate: candidate, sizing: sizing)
  end

  private

  # Structural stop = the swing extreme the structure signal referenced,
  # with a small ATR buffer. This is a placeholder stop model — refine
  # against your existing SMC-CE v5 stop logic before live use.
  def structural_stop(candles:, index:, direction:)
    lookback = @profile.structure_lookback
    window = candles[[index - lookback, 0].max...index]
    atr = Indicators.atr(candles[0..index], 14)[index] || 0.0

    if direction == :long
      window.map { |c| c[:low] }.min - atr * 0.5
    else
      window.map { |c| c[:high] }.max + atr * 0.5
    end
  end
end

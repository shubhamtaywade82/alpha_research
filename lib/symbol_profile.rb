# frozen_string_literal: true

# SymbolProfile holds per-symbol tuning parameters.
#
# IMPORTANT: These are starting priors based on known qualitative behavior
# (SOL trends hard, ETH is macro-beta-driven, XRP is choppier / more prone
# to manipulation-driven fakeouts). None of these numbers are backtested.
# Every parameter here MUST be swept and validated through the walk-forward
# harness before being trusted. Treat this file as a config surface for
# calibration, not a source of truth.
class SymbolProfile
  Params = Struct.new(
    :symbol,
    :adx_trend_threshold,      # min ADX to confirm a trend regime
    :atr_percentile_lookback,  # bars for ATR percentile rank
    :bb_width_lookback,        # bars for Bollinger Band width regime
    :ema_fast,
    :ema_slow,
    :r_multiple_target,        # target R for trend-following exits
    :max_leverage,             # hard cap, never exceeds account-level 10x
    :liquidation_buffer_pct,   # min distance to liquidation as % of entry
    :funding_extreme_threshold, # abs funding rate considered "extreme"
    :structure_lookback,       # bars for swing high/low structure detection
    :weight_trend,
    :weight_structure,
    :weight_funding_carry,
    keyword_init: true
  )

  PROFILES = {
    "SOLUSDT" => Params.new(
      symbol: "SOLUSDT",
      adx_trend_threshold: 20.0,
      atr_percentile_lookback: 100,
      bb_width_lookback: 50,
      ema_fast: 21,
      ema_slow: 55,
      r_multiple_target: 3.0,
      max_leverage: 10,
      liquidation_buffer_pct: 0.15,
      funding_extreme_threshold: 0.0005,
      structure_lookback: 20,
      weight_trend: 0.45,
      weight_structure: 0.35,
      weight_funding_carry: 0.20
    ),
    "ETHUSDT" => Params.new(
      symbol: "ETHUSDT",
      adx_trend_threshold: 23.0,
      atr_percentile_lookback: 100,
      bb_width_lookback: 50,
      ema_fast: 21,
      ema_slow: 55,
      r_multiple_target: 2.5,
      max_leverage: 10,
      liquidation_buffer_pct: 0.15,
      funding_extreme_threshold: 0.0004,
      structure_lookback: 20,
      weight_trend: 0.40,
      weight_structure: 0.40,
      weight_funding_carry: 0.20
    ),
    "XRPUSDT" => Params.new(
      symbol: "XRPUSDT",
      adx_trend_threshold: 27.0,
      atr_percentile_lookback: 100,
      bb_width_lookback: 50,
      ema_fast: 13,
      ema_slow: 34,
      r_multiple_target: 2.0,
      max_leverage: 5,               # lower cap: choppier/manipulation-prone
      liquidation_buffer_pct: 0.20,  # wider buffer, same reason
      funding_extreme_threshold: 0.0004,
      structure_lookback: 15,
      weight_trend: 0.30,
      weight_structure: 0.30,
      weight_funding_carry: 0.40      # mean-reversion/carry weighted higher
    )
  }.freeze

  def self.for(symbol)
    PROFILES.fetch(symbol) do
      raise ArgumentError, "No SymbolProfile configured for #{symbol}. " \
        "Refusing to guess parameters for an unconfigured symbol."
    end
  end
end

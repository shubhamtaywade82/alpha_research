# Crypto Perpetuals Alpha-Research Engine (SOLUSDT / ETHUSDT / XRPUSDT)

## What this is
A rule-based, symbol-differentiated signal engine for USDS-M perpetual
futures. **It has not been backtested or walk-forward validated yet.**
Every threshold in `SymbolProfile` is a qualitative starting prior, not a
calibrated parameter. Do not trade this. It is a candidate architecture
to run through `WalkForwardValidator` against real historical data.

## Architecture

```
Candles + Funding Rate
        |
        v
RegimeClassifier (ADX / ATR%ile / BB width)
        |
        +--> TrendFollowingSignal   (Seykota-style, regime-gated)
        +--> SmcStructureSignal     (break-of-structure / liquidity sweep)
        +--> FundingCarrySignal     (independent, non-directional overlay)
        |
        v
ConfluenceScorer (weighted, conflict-guarded, min-score gate)
        |
        v
PositionSizer (risk% + max-leverage + liquidation-buffer caps, min wins)
        |
        v
StrategyEngine::Evaluation (per-bar output)
```

## Files

- `lib/symbol_profile.rb` — per-symbol parameters (SOL/ETH/XRP differentiated)
- `lib/indicators.rb` — pure-Ruby EMA/ATR/ADX/BB-width, no gem dependency
- `lib/regime_classifier.rb` — 4-state regime (trending bull/bear, high/low-vol range)
- `lib/signals/trend_following_signal.rb` — Seykota-style continuation
- `lib/signals/smc_structure_signal.rb` — simplified BOS/liquidity-sweep detector
- `lib/signals/funding_carry_signal.rb` — funding-rate crowding/carry bias
- `lib/confluence_scorer.rb` — weighted combination + conflict guard + min-score gate
- `lib/position_sizer.rb` — risk/leverage/liquidation-buffer sizing
- `lib/strategy_engine.rb` — orchestrates the full per-bar pipeline
- `lib/walk_forward_validator.rb` — nested folds with purge/embargo (not yet run on real data)
- `spec/smoke_test.rb` — synthetic-data execution proof (proves it *runs*, not that it *works*)

## What's genuinely uncertain / needs your judgment

1. **SMC structure signal is a simplification**, not your full SMC-CE v5
   indicator. It only detects swing-extreme sweeps and breaks. If you want
   parity with your existing indicator's order-block/FVG logic, that needs
   to be ported in separately.
2. **Structural stop placement** (`StrategyEngine#structural_stop`) is a
   placeholder — swing extreme ± 0.5 ATR. Should be reconciled with
   whatever stop logic your existing CoinDCX/Delta pipeline already validated.
3. **Funding-carry weighting** for XRP (0.40) is a guess based on "XRP is
   choppier so lean on carry more" — this is exactly the kind of prior
   that walk-forward testing might falsify.
4. **No transaction costs, slippage, or funding payment accrual** are
   modeled yet in the sizing/scoring layer — needed before any P&L
   expectation is meaningful.

## Running against real mainnet data (locally)

**Run this on your own machine, not a cloud/datacenter sandbox** — Binance's
mainnet REST API (`fapi.binance.com`) returns HTTP 451 to datacenter-class
IPs per their Terms of Service geo-restrictions. A normal residential/office
connection is fine. No API key or secret needed — all endpoints used are
public market data.

**Requirements:** Ruby 3.x. No gems — everything uses stdlib (`net/http`,
`json`, `uri`) deliberately, so there's nothing to `bundle install`.

```bash
ruby bin/run_real_data_analysis.rb
```

This pulls 90 days of 15m candles + funding rate history for SOLUSDT,
ETHUSDT, XRPUSDT from mainnet, runs the discovery pipeline at both
`entry_delay_bars: 1` and `entry_delay_bars: 3`, and prints a per-symbol,
per-regime bucket table (`n`, `mean_r`, `win_rate`, `baseline_r`, `edge`),
flagging any bucket that clears `DynamicRiskPlanner`'s tradeable gate.

It now also runs a walk-forward out-of-sample pass per symbol/delay:

- discover tradeable regime buckets on each train fold
- trade only those buckets on the next test fold
- report fold/aggregate `gross_r`, `net_r`, `baseline`, and `alpha`

`net_r` includes explicit round-trip friction assumptions of 4 bps fee per
side, 2 bps slippage per side, plus prorated funding accrual over the
trade hold. `alpha` is the OOS net expectancy minus the unconditional
baseline net expectancy in the same regime buckets and dominant
train-selected directions.

Raw API responses are cached under `data/cache/*.json` so re-runs don't
re-hit the API. Force a fresh pull with:

```bash
FORCE_REFRESH=1 ruby bin/run_real_data_analysis.rb
```

**Before trusting any positive OOS result the script prints:** this is
still one historical window on one pull, with priors in `SymbolProfile`
that remain hand-authored rather than calibrated. Treat the output as a
useful falsification pass, not as deployment approval.

`spec/mock_binance_shape_test.rb` verifies the parsing layer (string
prices, ms timestamps, funding alignment) against data shaped exactly like
Binance's real JSON — run it any time to sanity-check the loader without
touching the network.

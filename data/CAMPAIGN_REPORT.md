# Alpha Research Campaign Report — SOL/ETH/XRP USDS-M Perps

Generated from `data/experiments.jsonl` (experiment DB), `data/finalists.json`, and `data/holdout_results.json`.

## Calibrated SymbolProfile (Phase 1)

| Symbol | ADX threshold | EMA fast/slow | R target | Calibration TF | Weighted edge | Events |
|---|---|---|---|---|---|---|
| XRPUSDT | 18.0 | 13/34 | 3.0 | 1h | 0.161 | 1178 |
| ETHUSDT | 26.0 | 13/34 | 3.0 | 1h | 0.141 | 1247 |
| SOLUSDT | 18.0 | 34/89 | 2.0 | 1h | 0.089 | 1227 |

## Finalist Leaderboard — Research OOS vs Holdout (Phases 2-5)

| Rank | Symbol | Family | TF pair | Params | Research alpha_R (pooled) | Research net_R (pooled) | Holdout net_R | Holdout trades | Holdout status |
|---|---|---|---|---|---|---|---|---|---|
| 1 | XRPUSDT | confluence | 2h+4h | thr=0.65 trend_heavy htf=true stop=1.0 r=2.0 h=20 | 0.488 | 0.454 | 0.008 | 11 | PASSED |
| 2 | XRPUSDT | confluence | 2h+4h | thr=0.65 trend_heavy htf=false stop=1.0 r=2.0 h=20 | 0.488 | 0.454 | 0.008 | 11 | PASSED |
| 3 | XRPUSDT | discovery | 2h+4h | stop=1.5 r=2.0 h=40 delay=1 | 0.417 | 0.161 | -0.398 | 26 | FAILED |
| 4 | ETHUSDT | discovery | 1h+4h | stop=1.0 r=3.0 h=10 delay=1 | 0.4 | 0.193 | -0.143 | 21 | FAILED |
| 5 | XRPUSDT | discovery | 1h+4h | stop=1.0 r=1.5 h=40 delay=3 | 0.383 | 0.011 | -0.287 | 79 | FAILED |
| 6 | SOLUSDT | discovery | 1h+4h | stop=1.0 r=3.0 h=20 delay=1 | 0.358 | 0.138 | -0.474 | 16 | FAILED |
| 7 | SOLUSDT | discovery | 1h+4h | stop=1.0 r=3.0 h=40 delay=3 | 0.357 | 0.006 | 0.087 | 21 | PASSED |
| 8 | SOLUSDT | confluence | 2h+4h | thr=0.55 trend_heavy htf=false stop=1.0 r=2.0 h=20 | 0.333 | 0.409 | 0.357 | 87 | PASSED |
| 9 | ETHUSDT | discovery | 1h+4h | stop=1.0 r=2.0 h=10 delay=1 | 0.299 | 0.057 | -0.162 | 21 | FAILED |
| 10 | XRPUSDT | discovery | 1h+4h | stop=1.0 r=2.0 h=10 delay=3 | 0.291 | 0.022 | -0.365 | 79 | FAILED |

**4/10 finalists passed the holdout confirmation** (positive net expectancy on the untouched final 20% of data).

## Combined Portfolio Simulation (Phase 4, research slice, walk-forward)

- Starting balance: $10000.0
- Ending balance: $66380.97 (563.81%)
- Max drawdown: 38.75%
- Sharpe (per-trade): 2.71
- Win rate: 42.4%
- Total trades: 1079

| Symbol | P&L ($) | Trades | Win rate |
|---|---|---|---|
| XRPUSDT | 24578.69 | 439 | 44.6% |
| SOLUSDT | 24347.53 | 478 | 41.2% |
| ETHUSDT | 7454.75 | 162 | 40.1% |

This mixes all 10 finalists, including duplicate/near-duplicate configs on the same symbol+bucket — inflates trade count without adding real diversification.

## Recommended Portfolio — holdout-confirmed, deduplicated (research slice, walk-forward)

The 4 finalists that passed holdout include one exact duplicate (XRPUSDT confluence config with `require_htf_alignment` true vs false producing identical trades) — deduplicated to 3 distinct strategies: XRPUSDT confluence 2h+4h, SOLUSDT discovery 1h+4h, SOLUSDT confluence 2h+4h.

- Starting balance: $10000.0
- Ending balance: $31065.7 (210.66%)
- Max drawdown: 24.47%
- Sharpe (per-trade): 3.012
- Win rate: 43.5%
- Total trades: 430

| Symbol | P&L ($) | Trades | Win rate |
|---|---|---|---|
| XRPUSDT | 5518.25 | 47 | 51.1% |
| SOLUSDT | 15547.45 | 383 | 42.6% |

All 3 of these strategies individually confirmed positive expectancy on the untouched holdout slice (see leaderboard above). This is the closest thing this campaign produced to an actionable result — still requires live/paper validation before real capital, given the holdout sample sizes (11-87 trades per strategy).

## Caveats

- Research slice = first 80% of 365d (1h) / 180d (15m) history; holdout = untouched final 20%, evaluated exactly once.
- `edge_over_baseline` / `alpha_net_r` compare against an unconditional same-regime, same-direction baseline — not zero. A bucket clears the bar only if it beats *doing nothing special in that regime*, after fees+slippage+funding.
- Sample-size tiers (SignatureAnalyzer) are a coarse trust gate, not a significance test (no t-test/bootstrap).
- The Phase 4 portfolio simulation compounds trades sequentially by entry time with a fixed 1% risk per trade; it does not model simultaneous open-notional/leverage caps across overlapping positions the way a live execution engine would.
- SOL/ETH/XRP are correlated high-beta alts — portfolio drawdown will exceed any single symbol's drawdown in a shared risk-off move; treat the combined Sharpe as optimistic versus live correlation shocks.
- All results are pre-decided by the stability gate in `bin/validate_candidates.rb` (alpha >= 0.10R, net expectancy > 0, >=40 trades, alpha positive in >=60% of OOS folds, survives a grid-neighborhood robustness check) — this is a falsification pass, not a promotion pass.
- **Ranking uses `pooled_alpha_net_r`/`pooled_net_expectancy_r` (trade-count-weighted across all OOS folds), not an unweighted mean of each fold's own average.** An earlier version of this campaign ranked by the unweighted per-fold mean and it produced a real Simpson's-paradox failure: a SOLUSDT config showed `mean_alpha_net_r=+0.59` (great) while the trade-weighted pooled result across the same 129 trades was -0.10R (a loser) — two high-volume folds were both losers, but three low-volume folds were winners, and the unweighted average let the small folds dominate. Every metric in this report is now the pooled, trade-weighted version.

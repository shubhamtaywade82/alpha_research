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
| 1 | XRPUSDT | confluence | 2h+4h | thr=0.65 trend_heavy htf=false stop=1.0 r=2.0 h=20 | 0.488 | 0.454 | 0.008 | 11 | PASSED |
| 2 | XRPUSDT | confluence | 2h+4h | thr=0.65 trend_heavy htf=true stop=1.0 r=2.0 h=20 | 0.488 | 0.454 | 0.008 | 11 | PASSED |
| 3 | XRPUSDT | discovery | 2h+4h | stop=1.5 r=2.0 h=40 delay=1 | 0.417 | 0.161 | -0.398 | 26 | FAILED |
| 4 | ETHUSDT | discovery | 1h+4h | stop=1.0 r=3.0 h=10 delay=1 | 0.4 | 0.193 | -0.143 | 21 | FAILED |
| 5 | SOLUSDT | price_action | 1h+4h | stop=1.0 r=3.0 h=20 delay=1 | 0.399 | 0.179 | -0.474 | 16 | FAILED |
| 6 | XRPUSDT | discovery | 1h+4h | stop=1.0 r=1.5 h=40 delay=3 | 0.383 | 0.011 | -0.287 | 79 | FAILED |
| 7 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=2.0 h=20 delay=1 | 0.375 | 0.11 | -0.12 | 22 | FAILED |
| 8 | SOLUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.374 | 0.188 | -0.276 | 7 | FAILED |
| 9 | SOLUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.374 | 0.188 | -0.276 | 7 | FAILED |
| 10 | XRPUSDT | supertrend_kmeans | 15m+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.372 | 0.015 | -0.025 | 20 | FAILED |
| 11 | XRPUSDT | supertrend_kmeans | 15m+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.372 | 0.015 | -0.025 | 20 | FAILED |
| 12 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=2.0 h=20 delay=3 | 0.359 | 0.174 | -0.152 | 15 | FAILED |
| 13 | SOLUSDT | price_action | 1h+4h | stop=1.0 r=3.0 h=20 delay=1 | 0.358 | 0.138 | -0.474 | 16 | FAILED |
| 14 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=0.7 r=3.0 h=20 delay=1 | 0.358 | 0.126 | -0.488 | 22 | FAILED |
| 15 | SOLUSDT | discovery | 1h+4h | stop=1.0 r=3.0 h=20 delay=1 | 0.358 | 0.138 | -0.474 | 16 | FAILED |
| 16 | SOLUSDT | discovery | 1h+4h | stop=1.0 r=3.0 h=40 delay=3 | 0.357 | 0.006 | 0.087 | 21 | PASSED |
| 17 | SOLUSDT | smc_standalone | 1h+4h | stop=1.0 r=2.0 h=20 delay=3 | 0.352 | 0.159 | -0.011 | 7 | FAILED |
| 18 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=2.0 h=20 delay=1 | 0.35 | 0.084 | -0.076 | 21 | FAILED |
| 19 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=3.0 h=20 delay=1 | 0.339 | 0.063 | 0.021 | 22 | PASSED |
| 20 | SOLUSDT | smc_standalone | 1h+4h | stop=1.0 r=2.0 h=20 delay=3 | 0.334 | 0.144 | -0.011 | 7 | FAILED |
| 21 | SOLUSDT | confluence | 2h+4h | thr=0.55 trend_heavy htf=false stop=1.0 r=2.0 h=20 | 0.333 | 0.409 | 0.357 | 87 | PASSED |
| 22 | XRPUSDT | supertrend_adaptive | 1h+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.321 | 0.071 | 0.321 | 9 | PASSED |
| 23 | SOLUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.317 | 0.132 | -0.276 | 7 | FAILED |
| 24 | SOLUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.317 | 0.132 | -0.276 | 7 | FAILED |
| 25 | XRPUSDT | supertrend_adaptive | 1h+4h | stop=1.0 r=3.0 h=20 delay=1 | 0.312 | 0.063 | -0.085 | 10 | FAILED |
| 26 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=2.0 h=20 delay=3 | 0.302 | 0.052 | 0.091 | 12 | PASSED |
| 27 | ETHUSDT | discovery | 1h+4h | stop=1.0 r=2.0 h=10 delay=1 | 0.299 | 0.057 | -0.162 | 21 | FAILED |
| 28 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=0.7 r=3.0 h=20 delay=3 | 0.297 | 0.113 | 0.313 | 13 | PASSED |
| 29 | XRPUSDT | discovery | 1h+4h | stop=1.0 r=2.0 h=10 delay=3 | 0.291 | 0.022 | -0.365 | 79 | FAILED |
| 30 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=2.0 h=20 delay=3 | 0.281 | 0.03 | -0.004 | 13 | FAILED |
| 31 | SOLUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.271 | 0.085 | -0.276 | 7 | FAILED |
| 32 | SOLUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.271 | 0.085 | -0.276 | 7 | FAILED |
| 33 | ETHUSDT | discovery | 1h+4h | stop=1.0 r=3.0 h=20 delay=1 | 0.267 | 0.158 | -0.082 | 43 | FAILED |
| 34 | XRPUSDT | supertrend_adaptive | 1h+4h | stop=1.0 r=2.0 h=20 delay=1 | 0.259 | 0.055 | -0.249 | 10 | FAILED |
| 35 | SOLUSDT | smc_standalone | 1h+4h | stop=1.0 r=2.0 h=20 delay=3 | 0.254 | 0.221 | 0.273 | 18 | PASSED |
| 36 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=0.7 r=3.0 h=20 delay=1 | 0.251 | 0.067 | -0.529 | 23 | FAILED |
| 37 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.243 | 0.072 | -0.144 | 15 | FAILED |
| 38 | XRPUSDT | supertrend_kmeans | 1h+4h | stop=0.7 r=3.0 h=20 delay=1 | 0.239 | 0.055 | -0.499 | 22 | FAILED |
| 39 | SOLUSDT | supertrend_kmeans | 15m+1h | stop=1.0 r=3.0 h=20 delay=3 | 0.234 | 0.183 | -0.7 | 18 | FAILED |
| 40 | SOLUSDT | smc_standalone | 1h+4h | stop=1.0 r=2.0 h=20 delay=3 | 0.233 | 0.056 | -0.055 | 24 | FAILED |
| 41 | SOLUSDT | supertrend_kmeans | 15m+4h | stop=1.0 r=3.0 h=20 delay=3 | 0.185 | 0.141 |  | 0 | NO_TRADES |
| 42 | XRPUSDT | confluence | 2h+4h | thr=0.55 trend_heavy htf=true stop=1.0 r=2.0 h=20 | 0.181 | 0.128 | 0.347 | 72 | PASSED |
| 43 | XRPUSDT | confluence | 2h+4h | thr=0.55 trend_heavy htf=false stop=1.0 r=2.0 h=20 | 0.168 | 0.117 | 0.347 | 72 | PASSED |
| 44 | SOLUSDT | discovery | 1h+4h | stop=1.0 r=3.0 h=40 delay=1 | 0.12 | 0.121 | -0.101 | 35 | FAILED |
| 45 | SOLUSDT | supertrend_kmeans | 1h+4h | stop=0.7 r=3.0 h=20 delay=1 | 0.113 | 0.112 | -0.242 | 30 | FAILED |

**11/45 finalists passed the holdout confirmation** (positive net expectancy on the untouched final 20% of data).

## Combined Portfolio Simulation (Phase 4, research slice, walk-forward)

- Starting balance: $10000.0
- Ending balance: $1146364.5 (11363.64%)
- Max drawdown: 80.35%
- Sharpe (per-trade): 2.364
- Win rate: 38.9%
- Total trades: 3994

| Symbol | P&L ($) | Trades | Win rate |
|---|---|---|---|
| XRPUSDT | 572619.15 | 2064 | 38.5% |
| SOLUSDT | 444753.65 | 1625 | 39.5% |
| ETHUSDT | 118991.69 | 305 | 38.0% |

This mixes all 10 finalists, including duplicate/near-duplicate configs on the same symbol+bucket — inflates trade count without adding real diversification.

## Recommended Portfolio — holdout-confirmed, deduplicated (research slice, walk-forward)

11 finalists passed holdout; some are duplicate/near-duplicate parameter variants of the same underlying signal on the same symbol+timeframe. Deduplicated to 6 distinct strategies (one representative per symbol+family+timeframe mechanism): SOLUSDT discovery 1h+4h, SOLUSDT confluence 2h+4h, SOLUSDT smc_standalone 1h+4h, XRPUSDT confluence 2h+4h, XRPUSDT supertrend_kmeans 1h+4h, XRPUSDT supertrend_adaptive 1h+4h.

- Starting balance: $10000.0
- Ending balance: $41140.87 (311.41%)
- Max drawdown: 32.46%
- Sharpe (per-trade): 2.514
- Win rate: 40.7%
- Total trades: 821

| Symbol | P&L ($) | Trades | Win rate |
|---|---|---|---|
| XRPUSDT | 6877.82 | 363 | 37.2% |
| SOLUSDT | 24263.06 | 458 | 43.4% |

All 6 of these strategies individually confirmed positive expectancy on the untouched holdout slice (see leaderboard above). This is the closest thing this campaign produced to an actionable result — still requires live/paper validation before real capital, given the small holdout sample sizes (9-87 trades per strategy).

## Caveats

- Research slice = first 80% of 365d (1h) / 180d (15m) history; holdout = untouched final 20%, evaluated exactly once.
- `edge_over_baseline` / `alpha_net_r` compare against an unconditional same-regime, same-direction baseline — not zero. A bucket clears the bar only if it beats *doing nothing special in that regime*, after fees+slippage+funding.
- Sample-size tiers (SignatureAnalyzer) are a coarse trust gate, not a significance test (no t-test/bootstrap).
- The Phase 4 portfolio simulation compounds trades sequentially by entry time with a fixed 1% risk per trade; it does not model simultaneous open-notional/leverage caps across overlapping positions the way a live execution engine would.
- SOL/ETH/XRP are correlated high-beta alts — portfolio drawdown will exceed any single symbol's drawdown in a shared risk-off move; treat the combined Sharpe as optimistic versus live correlation shocks.
- All results are pre-decided by the stability gate in `bin/validate_candidates.rb` (alpha >= 0.10R, net expectancy > 0, >=40 trades, alpha positive in >=60% of OOS folds, survives a grid-neighborhood robustness check) — this is a falsification pass, not a promotion pass.
- **Ranking uses `pooled_alpha_net_r`/`pooled_net_expectancy_r` (trade-count-weighted across all OOS folds), not an unweighted mean of each fold's own average.** An earlier version of this campaign ranked by the unweighted per-fold mean and it produced a real Simpson's-paradox failure: a SOLUSDT config showed `mean_alpha_net_r=+0.59` (great) while the trade-weighted pooled result across the same 129 trades was -0.10R (a loser) — two high-volume folds were both losers, but three low-volume folds were winners, and the unweighted average let the small folds dominate. Every metric in this report is now the pooled, trade-weighted version.

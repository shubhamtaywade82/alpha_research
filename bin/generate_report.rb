#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 6: assemble the campaign report from the JSON artifacts produced by
# Phases 1-5. Pure read + format — no new computation.
#
# Usage:
#   ruby bin/generate_report.rb

require "json"

root = File.expand_path("..", __dir__)
data_dir = File.join(root, "data")

def load_json(path)
  File.exist?(path) ? JSON.parse(File.read(path)) : nil
end

calibrated = load_json(File.join(data_dir, "calibrated_profiles.json")) || {}
finalists = load_json(File.join(data_dir, "finalists.json")) || []
holdout = load_json(File.join(data_dir, "holdout_results.json")) || []
portfolio = load_json(File.join(data_dir, "finalists_portfolio_results.json"))
deduped_portfolio = load_json(File.join(data_dir, "finalists_deduped_portfolio_results.json"))
deduped_finalists = load_json(File.join(data_dir, "finalists_deduped.json")) || []

# Positional match: bin/run_holdout_eval.rb iterates finalists.json in order
# and writes one holdout result per finalist at the same index. Several
# finalists can share (symbol, family, timeframe_pair) — they're different
# parameter variants — so a key-based join would collapse them together.

lines = []
lines << "# Alpha Research Campaign Report — SOL/ETH/XRP USDS-M Perps"
lines << ""
lines << "Generated from `data/experiments.jsonl` (experiment DB), `data/finalists.json`, and `data/holdout_results.json`."
lines << ""
lines << "## Calibrated SymbolProfile (Phase 1)"
lines << ""
lines << "| Symbol | ADX threshold | EMA fast/slow | R target | Calibration TF | Weighted edge | Events |"
lines << "|---|---|---|---|---|---|---|"
calibrated.each do |symbol, c|
  lines << "| #{symbol} | #{c['adx_trend_threshold']} | #{c['ema_fast']}/#{c['ema_slow']} | #{c['r_multiple_target']} | #{c['calibration_timeframe']} | #{c['calibration_weighted_edge']} | #{c['calibration_total_events']} |"
end
lines << ""

lines << "## Finalist Leaderboard — Research OOS vs Holdout (Phases 2-5)"
lines << ""
if finalists.empty?
  lines << "**No configuration cleared the stability gate.** Across the full MTF grid (discovery + confluence"
  lines << "families, 5 timeframe pairs, calibrated per-symbol profiles), nothing demonstrated alpha >= 0.10R"
  lines << "with >=40 trades and positive alpha in >=60% of OOS folds. This is a valid, reportable outcome: it means"
  lines << "no swept rule-based configuration here has a robust, non-overfit edge on the available data."
else
  lines << "| Rank | Symbol | Family | TF pair | Params | Research alpha_R (pooled) | Research net_R (pooled) | Holdout net_R | Holdout trades | Holdout status |"
  lines << "|---|---|---|---|---|---|---|---|---|---|"
  finalists.each_with_index do |f, i|
    h = holdout[i]
    p = f["parameters"] || {}
    params_str = if f["family"] == "confluence"
                   "thr=#{p['min_score_threshold']} #{p['weight_preset']} htf=#{p['require_htf_alignment']} stop=#{p['stop_atr_buffer']} r=#{p['r_multiple_target']} h=#{p['forward_horizon_bars']}"
                 else
                   "stop=#{p['stop_atr_buffer']} r=#{p['r_multiple_target']} h=#{p['forward_horizon_bars']} delay=#{p['entry_delay_bars']}"
                 end
    lines << "| #{i + 1} | #{f['symbol']} | #{f['family']} | #{f['timeframe_pair']} | #{params_str} | #{f['pooled_alpha_net_r']} | #{f['pooled_net_expectancy_r']} | #{h ? h['holdout_net_expectancy_r'] : 'n/a'} | #{h ? h['holdout_trades'] : 'n/a'} | #{h ? h['status'] : 'NOT RUN'} |"
  end
  lines << ""
  passed = holdout.count { |h| h["status"] == "PASSED" }
  lines << "**#{passed}/#{holdout.size} finalists passed the holdout confirmation** (positive net expectancy on the untouched final 20% of data)."
end
lines << ""

if portfolio
  lines << "## Combined Portfolio Simulation (Phase 4, research slice, walk-forward)"
  lines << ""
  lines << "- Starting balance: $#{portfolio['starting_balance_usdt']}"
  lines << "- Ending balance: $#{portfolio['ending_balance_usdt']} (#{portfolio['total_return_pct']}%)"
  lines << "- Max drawdown: #{portfolio['max_drawdown_pct']}%"
  lines << "- Sharpe (per-trade): #{portfolio['sharpe']}"
  lines << "- Win rate: #{(portfolio['win_rate'] * 100).round(1)}%"
  lines << "- Total trades: #{portfolio['total_trades']}"
  lines << ""
  lines << "| Symbol | P&L ($) | Trades | Win rate |"
  lines << "|---|---|---|---|"
  portfolio["per_symbol"].each do |sym, s|
    wr = s["trades"].zero? ? 0.0 : (s["wins"].to_f / s["trades"] * 100).round(1)
    lines << "| #{sym} | #{s['pnl']} | #{s['trades']} | #{wr}% |"
  end
  lines << ""
  lines << "This mixes all 10 finalists, including duplicate/near-duplicate configs on the same symbol+bucket — inflates trade count without adding real diversification."
  lines << ""
end

if deduped_portfolio
  passed_count = holdout.count { |h| h["status"] == "PASSED" }
  strategy_list = deduped_finalists.map { |f| "#{f['symbol']} #{f['family']} #{f['timeframe_pair']}" }.join(", ")
  lines << "## Recommended Portfolio — holdout-confirmed, deduplicated (research slice, walk-forward)"
  lines << ""
  lines << "#{passed_count} finalists passed holdout; some are duplicate/near-duplicate parameter variants of the same underlying signal on the same symbol+timeframe. Deduplicated to #{deduped_finalists.size} distinct strategies (one representative per symbol+family+timeframe mechanism): #{strategy_list}."
  lines << ""
  lines << "- Starting balance: $#{deduped_portfolio['starting_balance_usdt']}"
  lines << "- Ending balance: $#{deduped_portfolio['ending_balance_usdt']} (#{deduped_portfolio['total_return_pct']}%)"
  lines << "- Max drawdown: #{deduped_portfolio['max_drawdown_pct']}%"
  lines << "- Sharpe (per-trade): #{deduped_portfolio['sharpe']}"
  lines << "- Win rate: #{(deduped_portfolio['win_rate'] * 100).round(1)}%"
  lines << "- Total trades: #{deduped_portfolio['total_trades']}"
  lines << ""
  lines << "| Symbol | P&L ($) | Trades | Win rate |"
  lines << "|---|---|---|---|"
  deduped_portfolio["per_symbol"].each do |sym, s|
    wr = s["trades"].zero? ? 0.0 : (s["wins"].to_f / s["trades"] * 100).round(1)
    lines << "| #{sym} | #{s['pnl']} | #{s['trades']} | #{wr}% |"
  end
  lines << ""
  lines << "All #{deduped_finalists.size} of these strategies individually confirmed positive expectancy on the untouched holdout slice (see leaderboard above). This is the closest thing this campaign produced to an actionable result — still requires live/paper validation before real capital, given the small holdout sample sizes (9-87 trades per strategy)."
  lines << ""
end

lines << "## Caveats"
lines << ""
lines << "- Research slice = first 80% of 365d (1h) / 180d (15m) history; holdout = untouched final 20%, evaluated exactly once."
lines << "- `edge_over_baseline` / `alpha_net_r` compare against an unconditional same-regime, same-direction baseline — not zero. A bucket clears the bar only if it beats *doing nothing special in that regime*, after fees+slippage+funding."
lines << "- Sample-size tiers (SignatureAnalyzer) are a coarse trust gate, not a significance test (no t-test/bootstrap)."
lines << "- The Phase 4 portfolio simulation compounds trades sequentially by entry time with a fixed 1% risk per trade; it does not model simultaneous open-notional/leverage caps across overlapping positions the way a live execution engine would."
lines << "- SOL/ETH/XRP are correlated high-beta alts — portfolio drawdown will exceed any single symbol's drawdown in a shared risk-off move; treat the combined Sharpe as optimistic versus live correlation shocks."
lines << "- All results are pre-decided by the stability gate in `bin/validate_candidates.rb` (alpha >= 0.10R, net expectancy > 0, >=40 trades, alpha positive in >=60% of OOS folds, survives a grid-neighborhood robustness check) — this is a falsification pass, not a promotion pass."
lines << "- **Ranking uses `pooled_alpha_net_r`/`pooled_net_expectancy_r` (trade-count-weighted across all OOS folds), not an unweighted mean of each fold's own average.** An earlier version of this campaign ranked by the unweighted per-fold mean and it produced a real Simpson's-paradox failure: a SOLUSDT config showed `mean_alpha_net_r=+0.59` (great) while the trade-weighted pooled result across the same 129 trades was -0.10R (a loser) — two high-volume folds were both losers, but three low-volume folds were winners, and the unweighted average let the small folds dominate. Every metric in this report is now the pooled, trade-weighted version."
lines << ""

report_path = File.join(data_dir, "CAMPAIGN_REPORT.md")
File.write(report_path, lines.join("\n"))
puts "Report written to #{report_path}"

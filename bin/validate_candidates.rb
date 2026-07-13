#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 3: rank every walk-forward experiment (both the swing-discovery
# family from bin/run_multitimeframe_research.rb and the confluence family
# from bin/run_confluence_walkforward.rb) by OOS alpha, apply stability
# filters, and write the survivors to data/finalists.json for Phase 4/5.
#
# Usage:
#   ruby bin/validate_candidates.rb

require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/experiment_store"

EXPERIMENT_PATH = File.join(root, "data", "experiments.jsonl")
FINALISTS_PATH = File.join(root, "data", "finalists.json")

MIN_ALPHA_NET_R = 0.10
MIN_TOTAL_TRADES = 40
MIN_FOLD_ALPHA_POSITIVE_RATE = 0.60
TOP_N = 10

unless File.exist?(EXPERIMENT_PATH)
  puts "No experiment database found at #{EXPERIMENT_PATH}"
  puts "Run `ruby bin/sweep_parameters.rb` and `ruby bin/run_multitimeframe_research.rb` first."
  exit 1
end

store = ExperimentStore.new(EXPERIMENT_PATH)

def aggregate_of(exp)
  exp.dig("walk_forward", "aggregate")
end

# IMPORTANT: gate and rank on pooled_* (trade-count-weighted across all
# folds), not mean_* (unweighted average of each fold's own mean). mean_*
# lets a handful of small, lucky folds outvote the folds with most of the
# actual trade volume — a real Simpson's-paradox failure mode found during
# this campaign: a config with mean_alpha_net_r=+0.59 had pooled (i.e. the
# expectancy an actual trader pooling every OOS trade would have realized)
# net expectancy of -0.10R, because two high-trade-count folds were both
# losers while three small folds were winners and the unweighted average
# let the small folds dominate. pooled_* cannot be fooled this way.
def stable?(exp, agg)
  return false if agg.nil? || agg["note"]
  return false unless agg["pooled_alpha_net_r"] && agg["pooled_alpha_net_r"] >= MIN_ALPHA_NET_R
  return false unless agg["pooled_net_expectancy_r"] && agg["pooled_net_expectancy_r"].positive?
  return false unless agg["total_trades"] && agg["total_trades"] >= MIN_TOTAL_TRADES

  folds_with_trades = agg["folds_with_trades"] || 0
  positive_folds = agg["folds_with_positive_alpha"]
  return false if positive_folds.nil? || folds_with_trades.zero?

  (positive_folds.to_f / folds_with_trades) >= MIN_FOLD_ALPHA_POSITIVE_RATE
end

candidates = store.query(phase: "mtf_walk_forward") + store.query(phase: "confluence_walk_forward")
puts "Scanning #{candidates.size} walk-forward experiments (discovery + confluence)..."

stable_candidates = candidates.select { |exp| stable?(exp, aggregate_of(exp)) }
puts "#{stable_candidates.size} pass the stability gate (alpha>=#{MIN_ALPHA_NET_R}R, net_expectancy>0, trades>=#{MIN_TOTAL_TRADES}, alpha-positive folds>=#{(MIN_FOLD_ALPHA_POSITIVE_RATE * 100).round}%)."

def neighborhood_survives?(exp, all_by_key)
  # Reject spiky isolated grid points: a real edge should survive at least
  # one adjacent grid step in stop_atr_buffer or forward_horizon_bars.
  params = exp["parameters"]
  key_prefix = [exp["symbol"], exp["family"], exp["timeframe_pair"]]
  neighbors = all_by_key[key_prefix] || []
  return true if neighbors.size <= 1

  agg = aggregate_of(exp)
  own_alpha = agg["pooled_alpha_net_r"]
  close_neighbors = neighbors.reject { |n| n.equal?(exp) }.select do |n|
    np = n["parameters"]
    same_r = np["r_multiple_target"] == params["r_multiple_target"] || np["min_score_threshold"] == params["min_score_threshold"]
    same_r
  end
  return true if close_neighbors.empty?

  close_neighbors.any? do |n|
    n_alpha = aggregate_of(n)&.dig("pooled_alpha_net_r")
    n_alpha && n_alpha > 0 && own_alpha && (n_alpha - own_alpha).abs < own_alpha.abs.clamp(0.01, Float::INFINITY)
  end
end

grouped = candidates.group_by { |exp| [exp["symbol"], exp["family"], exp["timeframe_pair"]] }
robust_candidates = stable_candidates.select { |exp| neighborhood_survives?(exp, grouped) }
puts "#{robust_candidates.size} survive the grid-neighborhood robustness check."

ranked = robust_candidates.sort_by { |exp| -(aggregate_of(exp)["pooled_alpha_net_r"] || 0) }
top = ranked.first(TOP_N)

finalists = top.map do |exp|
  agg = aggregate_of(exp)
  {
    symbol: exp["symbol"],
    family: exp["family"],
    timeframe_pair: exp["timeframe_pair"],
    parameters: exp["parameters"],
    pooled_alpha_net_r: agg["pooled_alpha_net_r"],
    pooled_net_expectancy_r: agg["pooled_net_expectancy_r"],
    pooled_win_rate: agg["pooled_win_rate"],
    mean_sharpe: agg["mean_sharpe"],
    worst_fold_drawdown_r: agg["worst_fold_drawdown_r"],
    total_trades: agg["total_trades"],
    tradeable_buckets: agg["bucket_aggregates"]&.select { |b| b["trade_count"].positive? }&.map do |b|
      { bucket_key: b["bucket_key"], direction: b["direction"], trade_count: b["trade_count"], alpha_net_r: b["alpha_net_r"] }
    end
  }
end

File.write(FINALISTS_PATH, JSON.pretty_generate(finalists))
puts "\n#{finalists.size} finalists written to #{FINALISTS_PATH}"

puts "\n#{'=' * 100}"
puts "FINALIST LEADERBOARD (ranked by pooled_alpha_net_r — trade-count-weighted, not per-fold-averaged)"
puts "=" * 100
puts format("%-9s %-11s %-10s %8s %8s %8s %6s", "Symbol", "Family", "TF pair", "Alpha_R", "NetExp_R", "Trades", "WR")
finalists.each do |f|
  puts format("%-9s %-11s %-10s %+8.3f %+8.3f %8d %6s",
              f[:symbol], f[:family], f[:timeframe_pair], f[:pooled_alpha_net_r] || 0.0, f[:pooled_net_expectancy_r] || 0.0,
              f[:total_trades] || 0, (f[:pooled_win_rate] || 0.0).round(3))
end

if finalists.empty?
  puts "\nNo configuration cleared the stability gate. This is a valid, reportable outcome:"
  puts "no swept config here has demonstrated robust OOS edge on the available data."
end

puts "\nRun `ruby bin/run_holdout_eval.rb` once, on the frozen finalist list, to confirm (or falsify) these on unseen data."

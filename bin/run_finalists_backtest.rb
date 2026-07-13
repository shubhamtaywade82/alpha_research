#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 4: portfolio simulation of the frozen finalist list (data/finalists.json)
# over the research slice (never the holdout). Re-derives each finalist's
# walk-forward OOS trades (same params as Phase 2/2-confluence), merges them
# chronologically across symbols/families into one equity curve, and reports
# portfolio-level Sharpe, max drawdown, and per-symbol attribution.
#
# ponytail: equity compounds sequentially by entry_ts with a fixed risk_pct
# per trade — it does not model simultaneous open-notional/leverage caps
# across overlapping trades the way BacktestSimulator does. Good enough to
# see correlation/drawdown effects across the 3 (highly-correlated) alts;
# upgrade to full notional-aware simulation if sizing precision matters.
#
# Usage:
#   ruby bin/run_finalists_backtest.rb

require "json"
require "time"

root = File.expand_path("..", __dir__)
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/trade_cost_model"
require_relative "../lib/walk_forward_discovery_evaluator"
require_relative "../lib/walk_forward_validator"
require_relative "../lib/candle_resampler"
require_relative "../lib/swing_point_detector"
require_relative "../lib/indicators"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/data_window"
require_relative "../lib/signals/trend_following_signal"
require_relative "../lib/signals/smc_structure_signal"
require_relative "../lib/signals/funding_carry_signal"
require_relative "../lib/confluence_scorer"
require_relative "../lib/supertrend_calculator"
require_relative "../lib/supertrend_flip_detector"
require_relative "../lib/smc_flip_detector"

SUPERTREND_BUILDERS = {
  "supertrend_percentile" => ->(candles, p) { SupertrendCalculator.percentile_scaled(candles, atr_period: p["atr_period"], min_mult: p["min_mult"], max_mult: p["max_mult"], pct_lookback: 100) },
  "supertrend_kmeans" => ->(candles, p) { SupertrendCalculator.kmeans_clustered(candles, atr_period: p["atr_period"], cluster_lookback: 100, mult_low: p["mult_low"], mult_mid: p["mult_mid"], mult_high: p["mult_high"]) },
  "supertrend_adaptive" => ->(candles, p) { SupertrendCalculator.fully_adaptive(candles, base_period: p["base_period"], min_period: p["min_period"], max_period: p["max_period"], min_mult: p["min_mult"], max_mult: p["max_mult"], er_lookback: p["er_lookback"], pct_lookback: 100) }
}.freeze

GATE_FILTERS = {
  "trending_only" => { trending_only: true, require_htf_alignment: false },
  "htf_aligned" => { trending_only: false, require_htf_alignment: true },
  "trending+htf" => { trending_only: true, require_htf_alignment: true }
}.freeze

def apply_gate(events, gate_label, entry_regimes, aligned_htf)
  gate = GATE_FILTERS[gate_label]
  return events if gate.nil? # nil or "ungated" -> no filtering

  events.select do |event|
    idx = event.confirmed_index
    regime = entry_regimes[idx]
    next false if regime.nil?
    next false if gate[:trending_only] && ![:trending_bull, :trending_bear].include?(regime.state)

    if gate[:require_htf_alignment]
      htf = aligned_htf[idx]
      next false if htf.nil? || htf.state != regime.state
    end

    true
  end
end

# swing-point-like events for a finalist: ATR-ZigZag (discovery/price_action),
# a SuperTrend-flip series (supertrend_* families), or SMC structure flips
# (smc_standalone) — all structurally interchangeable inputs to
# MoveLabeler/WalkForwardDiscoveryEvaluator. Applies the finalist's own
# "gate" parameter (trending_only / htf_aligned / trending+htf), if present
# — the SOL deep-dive sweep tested these as a hard pre-filter, so replaying
# a gated finalist without the gate would silently reproduce different
# (larger, ungated) trades than what was actually measured.
def events_for(finalist, entry_candles, profile, entry_regimes, aligned_htf)
  family = finalist["family"]
  params = finalist["parameters"]

  raw_events =
    if SUPERTREND_BUILDERS.key?(family)
      series = SUPERTREND_BUILDERS[family].call(entry_candles, params)
      SupertrendFlipDetector.detect(series, entry_candles)
    elsif family == "smc_standalone"
      smc_profile = profile.dup
      smc_profile.structure_lookback = params["structure_lookback"] if params["structure_lookback"]
      SmcFlipDetector.detect(entry_candles, smc_profile)
    elsif family == "price_action"
      SwingPointDetector.new(min_move_atr_multiple: params["min_move_atr_multiple"] || 1.5).detect(entry_candles)
    else
      SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(entry_candles)
    end

  apply_gate(raw_events, params["gate"], entry_regimes, aligned_htf)
end

CACHE_DIR = File.join(root, "data", "cache")
FINALISTS_PATH = File.join(root, "data", ENV["FINALISTS_FILE"] || "finalists.json")
RESULTS_PATH = File.join(root, "data", ENV["RESULTS_FILE"] || "finalists_portfolio_results.json")

STARTING_BALANCE_USDT = 10_000.0
RISK_PCT_PER_TRADE = (ENV["RISK_PCT"] || 0.01).to_f
FEE_BPS_PER_SIDE = 4.0
SLIPPAGE_BPS_PER_SIDE = 2.0

TF_PAIR_DEFS = {
  "15m+1h" => { base: "15m_180d", base_minutes: 15, entry_factor: 1, htf_factor: 4, n_folds: 6, htf_label: "1h" },
  "15m+4h" => { base: "15m_180d", base_minutes: 15, entry_factor: 1, htf_factor: 16, n_folds: 6, htf_label: "4h" },
  "1h+4h" => { base: "1h_365d", base_minutes: 60, entry_factor: 1, htf_factor: 4, n_folds: 8, htf_label: "4h" },
  "2h+4h" => { base: "1h_365d", base_minutes: 60, entry_factor: 2, htf_factor: 4, n_folds: 8, htf_label: "4h" },
  "4h+1d" => { base: "1h_365d", base_minutes: 60, entry_factor: 4, htf_factor: 24, n_folds: 8, htf_label: "1d" }
}.freeze

unless File.exist?(FINALISTS_PATH)
  puts "No finalists found at #{FINALISTS_PATH}. Run bin/validate_candidates.rb first."
  exit 1
end

finalists = JSON.parse(File.read(FINALISTS_PATH))
if finalists.empty?
  puts "finalists.json is empty — no config cleared the stability gate. Nothing to simulate."
  exit 0
end

base_cache = {}

def load_base(cache_dir, symbol, base_key)
  raw_klines = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_klines_#{base_key}.json")))
  raw_funding = JSON.parse(File.read(File.join(cache_dir, "#{symbol}_funding_365d.json")))
  candles = BinanceDataLoader.klines_to_candles(raw_klines)
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  [DataWindow.research_slice(candles), DataWindow.research_slice(funding_series)]
end

def discovery_trades(finalist, cache_dir, base_cache)
  pair = TF_PAIR_DEFS.fetch(finalist["timeframe_pair"])
  symbol = finalist["symbol"]
  profile = SymbolProfile.for(symbol)
  p = finalist["parameters"]

  base_candles, base_funding = (base_cache[[symbol, pair[:base]]] ||= load_base(cache_dir, symbol, pair[:base]))
  entry_candles = CandleResampler.resample_candles(base_candles, pair[:entry_factor])
  entry_funding = CandleResampler.resample_series(base_funding, pair[:entry_factor])
  htf_candles = CandleResampler.resample_candles(base_candles, pair[:htf_factor])

  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_htf = CandleResampler.align_higher_regimes(lower_candles: entry_candles, higher_candles: htf_candles, higher_regimes: htf_regimes)
  entry_regimes = RegimeClassifier.new(profile).classify(entry_candles)
  swings = events_for(finalist, entry_candles, profile, entry_regimes, aligned_htf)
  atr_cache = Indicators.atr(entry_candles, 14)
  closes = entry_candles.map { |c| c[:close] }
  extractor = ContextFeatureExtractor.new(profile)
  extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
  extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)

  cost_model = TradeCostModel.new(fee_bps_per_side: FEE_BPS_PER_SIDE, slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE,
                                   bar_interval_minutes: pair[:base_minutes] * pair[:entry_factor])
  profile_for_run = profile.dup
  profile_for_run.r_multiple_target = p["r_multiple_target"]
  embargo_bars = p["forward_horizon_bars"] + (p["structure_lookback"] || profile.structure_lookback)

  result = WalkForwardDiscoveryEvaluator.new(
    profile: profile_for_run, cost_model: cost_model, entry_delay_bars: p["entry_delay_bars"],
    forward_horizon_bars: p["forward_horizon_bars"], stop_atr_buffer: p["stop_atr_buffer"],
    htf_regimes: aligned_htf,
    bucket_by: lambda { |ctx|
      htf = ctx.key?(:htf_aligned) ? ctx[:htf_aligned] : :unknown
      "#{ctx[:regime_state]}|#{pair[:htf_label]}_aligned=#{htf}"
    },
    regimes: entry_regimes, swings: swings, atr_cache: atr_cache, extractor: extractor
  ).evaluate(candles: entry_candles, funding_series: entry_funding, n_folds: pair[:n_folds], embargo_bars: embargo_bars)

  result[:folds].flat_map { |fold| fold.trades || [] }.map do |t|
    { symbol: symbol, entry_ts: t.entry_ts, exit_ts: t.exit_ts, net_r: t.net_r, direction: t.direction }
  end
end

def confluence_trades(finalist, cache_dir, base_cache)
  pair_label = finalist["timeframe_pair"]
  entry_label, _htf_label = pair_label.split("+")
  entry_factor = entry_label == "1h" ? 1 : 2
  symbol = finalist["symbol"]
  profile = SymbolProfile.for(symbol)
  p = finalist["parameters"]

  base_candles, base_funding = (base_cache[[symbol, "1h_365d"]] ||= load_base(cache_dir, symbol, "1h_365d"))
  entry_candles = CandleResampler.resample_candles(base_candles, entry_factor)
  entry_funding = CandleResampler.resample_series(base_funding, entry_factor)
  htf_candles = CandleResampler.resample_candles(base_candles, 4)

  entry_regimes = RegimeClassifier.new(profile).classify(entry_candles)
  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_htf = CandleResampler.align_higher_regimes(lower_candles: entry_candles, higher_candles: htf_candles, higher_regimes: htf_regimes)
  ema_fast_series = Indicators.ema(entry_candles.map { |c| c[:close] }, profile.ema_fast)
  atr_series = Indicators.atr(entry_candles, 14)

  weight_preset = p["weight_preset"]
  prof = profile.dup
  if weight_preset == "trend_heavy"
    prof.weight_trend = 0.6
    prof.weight_structure = 0.3
    prof.weight_funding_carry = 0.1
  end
  trend_signal = TrendFollowingSignal.new(prof)
  structure_signal = SmcStructureSignal.new(prof)
  funding_signal = FundingCarrySignal.new(prof)
  scorer = ConfluenceScorer.new(prof, min_score_threshold: p["min_score_threshold"])
  cost_model = TradeCostModel.new(fee_bps_per_side: FEE_BPS_PER_SIDE, slippage_bps_per_side: SLIPPAGE_BPS_PER_SIDE,
                                   bar_interval_minutes: entry_label == "1h" ? 60 : 120)
  n_folds = entry_label == "1h" ? 8 : 6
  embargo_bars = p["forward_horizon_bars"] + prof.structure_lookback
  folds = WalkForwardValidator.build_folds(total_bars: entry_candles.size, n_folds: n_folds, embargo_bars: embargo_bars)

  trades = []
  folds.each do |fold|
    fold.test_range.each do |idx|
      next if idx + p["forward_horizon_bars"] >= entry_candles.size

      regime = entry_regimes[idx]
      next if regime.nil?

      if p["require_htf_alignment"]
        htf = aligned_htf[idx]
        next if htf.nil? || htf.state != regime.state
      end

      candle = entry_candles[idx]
      trend = trend_signal.evaluate(regime: regime, candle: candle, ema_fast_val: ema_fast_series[idx], ema_slow_val: nil)
      structure = structure_signal.evaluate(candles: entry_candles[0..idx], index: idx)
      funding = funding_signal.evaluate(funding_rate: entry_funding[idx])
      candidate = scorer.score(trend: trend, structure: structure, funding: funding)
      next if candidate.direction == :none

      atr = atr_series[idx]
      next if atr.nil? || atr <= 0

      entry_price = candle[:close]
      stop_price = candidate.direction == :long ? entry_price - atr * p["stop_atr_buffer"] : entry_price + atr * p["stop_atr_buffer"]
      stop_dist = (entry_price - stop_price).abs
      next if stop_dist <= 0

      target_price = candidate.direction == :long ? entry_price + stop_dist * p["r_multiple_target"] : entry_price - stop_dist * p["r_multiple_target"]
      exit_index = nil
      exit_price = nil
      gross_r = nil
      last_bar = [idx + p["forward_horizon_bars"], entry_candles.size - 1].min

      ((idx + 1)..last_bar).each do |i|
        bar = entry_candles[i]
        if candidate.direction == :long
          if bar[:low] <= stop_price
            exit_index, exit_price, gross_r = i, stop_price, -1.0
            break
          elsif bar[:high] >= target_price
            exit_index, exit_price, gross_r = i, target_price, p["r_multiple_target"]
            break
          end
        else
          if bar[:high] >= stop_price
            exit_index, exit_price, gross_r = i, stop_price, -1.0
            break
          elsif bar[:low] <= target_price
            exit_index, exit_price, gross_r = i, target_price, p["r_multiple_target"]
            break
          end
        end
      end

      unless exit_index
        exit_index = last_bar
        exit_price = entry_candles[last_bar][:close]
        move = candidate.direction == :long ? exit_price - entry_price : entry_price - exit_price
        gross_r = move / stop_dist
      end

      event = Struct.new(:direction, :entry_price, :stop_price, :entry_index, :exit_index, :r_multiple).new(
        candidate.direction, entry_price, stop_price, idx, exit_index, gross_r.round(3)
      )
      net_r = cost_model.net_r_for_event(event: event, funding_series: entry_funding)
      trades << { symbol: symbol, entry_ts: candle[:ts], exit_ts: entry_candles[exit_index][:ts], net_r: net_r, direction: candidate.direction }
    end
  end
  trades
end

puts "Re-deriving OOS trades for #{finalists.size} finalists over the research slice..."
all_trades = finalists.flat_map do |finalist|
  trades = finalist["family"] == "confluence" ? confluence_trades(finalist, CACHE_DIR, base_cache) : discovery_trades(finalist, CACHE_DIR, base_cache)
  puts "  #{finalist['symbol']} #{finalist['family']} #{finalist['timeframe_pair']}: #{trades.size} trades"
  trades
end.sort_by { |t| t[:entry_ts] }

equity = STARTING_BALANCE_USDT
peak = equity
max_dd_pct = 0.0
equity_curve = []
pnl_values = []
per_symbol = Hash.new { |h, k| h[k] = { pnl: 0.0, trades: 0, wins: 0 } }

all_trades.each do |t|
  pnl = equity * RISK_PCT_PER_TRADE * t[:net_r]
  equity += pnl
  peak = [peak, equity].max
  dd = peak.zero? ? 0.0 : (peak - equity) / peak
  max_dd_pct = [max_dd_pct, dd].max
  pnl_values << pnl
  per_symbol[t[:symbol]][:pnl] += pnl
  per_symbol[t[:symbol]][:trades] += 1
  per_symbol[t[:symbol]][:wins] += 1 if pnl.positive?
  equity_curve << { entry_ts: t[:entry_ts], equity: equity.round(2) }
end

sharpe = 0.0
if pnl_values.size > 5
  mean = pnl_values.sum / pnl_values.size.to_f
  variance = pnl_values.sum { |v| (v - mean)**2 } / pnl_values.size.to_f
  std = Math.sqrt(variance)
  sharpe = std.zero? ? 0.0 : (mean / std) * Math.sqrt(pnl_values.size)
end

total_return_pct = ((equity - STARTING_BALANCE_USDT) / STARTING_BALANCE_USDT) * 100.0
win_rate = all_trades.empty? ? 0.0 : pnl_values.count(&:positive?) / pnl_values.size.to_f

puts "\n#{'=' * 70}"
puts "FINALIST PORTFOLIO — research slice, walk-forward OOS, #{all_trades.size} trades"
puts "=" * 70
puts format("Starting: $%.2f  Ending: $%.2f  Return: %+.2f%%", STARTING_BALANCE_USDT, equity, total_return_pct)
puts format("Max drawdown: %.2f%%  Sharpe (per-trade): %.2f  Win rate: %.1f%%", max_dd_pct * 100.0, sharpe, win_rate * 100.0)
puts "\nPer-symbol attribution:"
per_symbol.each do |sym, stats|
  wr = stats[:trades].zero? ? 0.0 : stats[:wins].to_f / stats[:trades]
  puts format("  %-9s pnl=%+9.2f trades=%-4d win_rate=%.1f%%", sym, stats[:pnl], stats[:trades], wr * 100.0)
end

File.write(RESULTS_PATH, JSON.pretty_generate(
  starting_balance_usdt: STARTING_BALANCE_USDT,
  ending_balance_usdt: equity.round(2),
  total_return_pct: total_return_pct.round(2),
  max_drawdown_pct: (max_dd_pct * 100.0).round(2),
  sharpe: sharpe.round(3),
  win_rate: win_rate.round(3),
  total_trades: all_trades.size,
  per_symbol: per_symbol.transform_values { |v| v.merge(pnl: v[:pnl].round(2)) },
  equity_curve: equity_curve
))
puts "\nResults written to #{RESULTS_PATH}"

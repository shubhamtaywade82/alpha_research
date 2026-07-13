# frozen_string_literal: true

require_relative "../lib/symbol_profile"
require_relative "../lib/trade_cost_model"
require_relative "../lib/walk_forward_discovery_evaluator"

def build_synthetic_series(leg_count: 18, bars_per_leg: 60, seed_price: 150.0)
  price = seed_price
  ts = Time.now.to_i - leg_count * bars_per_leg * 900
  candles = []

  leg_count.times do |leg|
    trending = leg.even?
    drift = trending ? (leg % 4 == 0 ? 0.4 : -0.35) : 0.0
    bars_per_leg.times do
      noise = (rand - 0.5) * (trending ? 0.9 : 1.5)
      price = [price + drift + noise, 1.0].max
      high = price + rand * 0.7
      low = price - rand * 0.7
      ts += 900
      candles << {
        open: price - drift, high: [high, price].max, low: [low, price].min,
        close: price, volume: rand(100..1000), ts: ts
      }
    end
  end

  candles
end

srand(42)
profile = SymbolProfile.for("SOLUSDT")
candles = build_synthetic_series
funding_series = Array.new(candles.size, 0.0)
cost_model = TradeCostModel.new(
  fee_bps_per_side: 4.0,
  slippage_bps_per_side: 2.0,
  bar_interval_minutes: 15
)

result = WalkForwardDiscoveryEvaluator.new(
  profile: profile,
  cost_model: cost_model,
  entry_delay_bars: 1
).evaluate(
  candles: candles,
  funding_series: funding_series,
  n_folds: 6,
  embargo_bars: 20
)

aggregate = result[:aggregate]
raise "No aggregate output" if aggregate.nil?
raise "Expected OOS trades, got none" if aggregate[:total_trades].to_i <= 0

gross = aggregate[:mean_gross_expectancy_r]
net = aggregate[:mean_net_expectancy_r]
raise "Missing expectancy values" if gross.nil? || net.nil?
raise "Net expectancy should not exceed gross expectancy with zero funding" if net > gross

puts "PASS: walk-forward OOS evaluator generated #{aggregate[:total_trades]} trades " \
     "(gross=#{gross}, net=#{net}, alpha=#{aggregate[:mean_alpha_net_r].inspect})"

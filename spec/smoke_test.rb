# frozen_string_literal: true

require_relative "../lib/strategy_engine"

# Generates synthetic OHLCV with a deliberate trend leg so the pipeline
# has something to react to. This proves the code EXECUTES correctly —
# it says nothing about whether the strategy has edge.
def synthetic_candles(n, seed_price: 150.0)
  price = seed_price
  ts = Time.now.to_i - n * 900
  Array.new(n) do |i|
    drift = i > n / 2 ? 0.15 : -0.02 # trend leg in second half
    noise = (rand - 0.5) * 1.2
    price = [price + drift + noise, 1.0].max
    high = price + rand * 0.8
    low = price - rand * 0.8
    ts += 900
    { open: price - drift, high: high, low: low, close: price, volume: rand(100..1000), ts: ts }
  end
end

%w[SOLUSDT ETHUSDT XRPUSDT].each do |symbol|
  engine = StrategyEngine.new(symbol)
  candles = synthetic_candles(300)
  funding_rate = 0.0006 # deliberately extreme, positive

  fired = 0
  errors = []

  (150...candles.size).each do |i|
    begin
      eval_result = engine.evaluate(
        candles: candles, index: i, funding_rate: funding_rate,
        account_equity: 10_000.0, risk_pct: 0.01
      )
      if eval_result.candidate.direction != :none
        fired += 1
        puts "#{symbol} bar=#{i} #{eval_result.candidate.direction} " \
             "score=#{eval_result.candidate.score.round(3)} " \
             "leverage=#{eval_result.sizing&.leverage_used} " \
             "capped_by=#{eval_result.sizing&.capped_by}"
      end
    rescue StandardError => e
      errors << "bar=#{i}: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    end
  end

  puts "== #{symbol}: #{fired} candidates fired over #{candles.size - 150} bars, #{errors.size} errors =="
  errors.first(3).each { |e| puts "  ERROR: #{e}" }
end

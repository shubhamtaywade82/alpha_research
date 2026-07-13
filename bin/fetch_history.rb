#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 0: fetch and cache longer history than the original 90d/15m snapshot.
# Must run locally (Binance mainnet returns HTTP 451 to datacenter IPs).
#
# Usage:
#   ruby bin/fetch_history.rb
#   FORCE_REFRESH=1 ruby bin/fetch_history.rb   # re-fetch even if cached

require "fileutils"
require "json"

root = File.expand_path("..", __dir__)
require_relative "../lib/binance_data_loader"

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
CACHE_DIR = File.join(root, "data", "cache")
FileUtils.mkdir_p(CACHE_DIR)

DATASETS = [
  { interval: "1h", days_back: 365, klines_key: "klines_1h_365d", funding_key: "funding_365d" },
  { interval: "15m", days_back: 180, klines_key: "klines_15m_180d", funding_key: nil }
].freeze

def cached_fetch(cache_dir, cache_key)
  path = File.join(cache_dir, "#{cache_key}.json")
  if !ENV["FORCE_REFRESH"] && File.exist?(path)
    puts "  [cache] #{cache_key}"
    return JSON.parse(File.read(path))
  end
  puts "  [fetching] #{cache_key}"
  data = yield
  File.write(path, JSON.generate(data))
  data
end

SYMBOLS.each do |symbol|
  puts "── #{symbol} ──────────────────────────────────────"

  DATASETS.each do |ds|
    raw_klines = cached_fetch(CACHE_DIR, "#{symbol}_#{ds[:klines_key]}") {
      BinanceDataLoader.fetch_klines(symbol: symbol, interval: ds[:interval], days_back: ds[:days_back])
    }
    candles = BinanceDataLoader.klines_to_candles(raw_klines)
    first_ts = Time.at(candles.first[:ts]).utc
    last_ts = Time.at(candles.last[:ts]).utc
    puts "    #{ds[:klines_key]}: #{candles.size} candles, #{first_ts} -> #{last_ts}"

    next unless ds[:funding_key]

    raw_funding = cached_fetch(CACHE_DIR, "#{symbol}_#{ds[:funding_key]}") {
      BinanceDataLoader.fetch_funding_rate_history(symbol: symbol, days_back: ds[:days_back])
    }
    puts "    #{ds[:funding_key]}: #{raw_funding.size} funding events"
  end
end

puts "\nDone. Research slice = first 80% of each series (see lib/data_window.rb);"
puts "final 20% is the holdout, touched only by bin/run_holdout_eval.rb."

# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Pulls real data from Binance USDS-M futures MAINNET (fapi.binance.com).
# Public endpoints only — no API key/secret used or required. Per standing
# rule: mainnet only, never testnet.
module BinanceDataLoader
  BASE = "https://fapi.binance.com"

  module_function

  def get(path, params)
    uri = URI("#{BASE}#{path}")
    uri.query = URI.encode_www_form(params)
    res = Net::HTTP.get_response(uri)
    raise "HTTP #{res.code} for #{uri}: #{res.body[0, 300]}" unless res.code.to_i == 200

    JSON.parse(res.body)
  end

  # Paginates backward from now until `days_back` of history is covered.
  def fetch_klines(symbol:, interval:, days_back:)
    end_time = (Time.now.to_f * 1000).to_i
    cutoff = end_time - (days_back * 24 * 60 * 60 * 1000)
    all = []

    loop do
      batch = get("/fapi/v1/klines", symbol: symbol, interval: interval, endTime: end_time, limit: 1500)
      break if batch.empty?

      all = batch + all
      earliest_open = batch.first[0]
      break if earliest_open <= cutoff

      end_time = earliest_open - 1
      sleep 0.15
    end

    all.select { |k| k[0] >= cutoff }
  end

  def fetch_funding_rate_history(symbol:, days_back:)
    end_time = (Time.now.to_f * 1000).to_i
    start_time = end_time - (days_back * 24 * 60 * 60 * 1000)
    all = []

    loop do
      batch = get("/fapi/v1/fundingRate", symbol: symbol, startTime: start_time, endTime: end_time, limit: 1000)
      break if batch.empty?

      all += batch
      break if batch.size < 1000

      start_time = batch.last["fundingTime"] + 1
      sleep 0.15
    end

    all
  end

  def klines_to_candles(raw)
    raw.map do |k|
      {
        ts: (k[0] / 1000).to_i,
        open: k[1].to_f,
        high: k[2].to_f,
        low: k[3].to_f,
        close: k[4].to_f,
        volume: k[5].to_f
      }
    end.sort_by { |c| c[:ts] }
  end

  # Forward-fills: each candle gets the most recent funding rate known as of
  # its own timestamp (funding events are sparser than 15m candles).
  def align_funding_series(candles, raw_funding)
    events = raw_funding.map { |f| [f["fundingTime"] / 1000, f["fundingRate"].to_f] }.sort_by(&:first)
    series = Array.new(candles.size)
    event_idx = 0
    current_rate = events.empty? ? 0.0 : events.first[1]

    candles.each_with_index do |c, i|
      while event_idx < events.size && events[event_idx][0] <= c[:ts]
        current_rate = events[event_idx][1]
        event_idx += 1
      end
      series[i] = current_rate
    end

    series
  end
end

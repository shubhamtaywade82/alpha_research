# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../lib/paper_broker"

# Self-check for PaperBroker's position lifecycle: stop-touch, target-touch,
# horizon-timeout, and cost/funding application on close. Uses a throwaway
# state file so it never touches the real paper_trading_state.json.

def assert(cond, msg)
  raise "FAIL: #{msg}" unless cond

  puts "  ok: #{msg}"
end

state_path = File.join(Dir.mktmpdir, "paper_broker_test_state.json")

# 1. Long position hits target -> positive net_r, equity increases
broker = PaperBroker.new(state_path: state_path, starting_equity_usdt: 10_000.0, risk_pct_per_trade: 0.01)
pos = broker.open_position(symbol: "SOLUSDT", strategy_id: "test_long_target", direction: :long,
                            entry_ts: 1000, entry_price: 100.0, stop_price: 95.0,
                            r_multiple_target: 2.0, horizon_bars: 5, interval_seconds: 3600)
bars = [{ ts: 4600, high: 111.0, low: 99.0, close: 110.0 }] # target = 100 + 5*2 = 110, touched
broker.process_bars_for_position!(pos, bars, funding_sum: 0.0)
assert(broker.summary[:closed_trades] == 1, "target-hit long closes as a trade")
assert(broker.summary[:total_net_pnl_usdt] > 0, "target-hit long increases equity (net_r ~= +2R minus costs)")

# 2. Short position hits stop -> negative net_r
broker2 = PaperBroker.new(state_path: File.join(Dir.mktmpdir, "s2.json"), starting_equity_usdt: 10_000.0)
pos2 = broker2.open_position(symbol: "XRPUSDT", strategy_id: "test_short_stop", direction: :short,
                              entry_ts: 1000, entry_price: 1.0, stop_price: 1.05,
                              r_multiple_target: 2.0, horizon_bars: 5, interval_seconds: 3600)
bars2 = [{ ts: 4600, high: 1.06, low: 0.98, close: 1.02 }] # stop = 1.05, touched (short: stop above entry)
broker2.process_bars_for_position!(pos2, bars2, funding_sum: 0.0)
assert(broker2.summary[:closed_trades] == 1, "stop-hit short closes as a trade")
assert(broker2.summary[:total_net_pnl_usdt] < 0, "stop-hit short decreases equity (net_r ~= -1R minus costs)")

# 3. Horizon timeout with no touch -> closes at last bar's close, gross_r from raw move
broker3 = PaperBroker.new(state_path: File.join(Dir.mktmpdir, "s3.json"), starting_equity_usdt: 10_000.0)
pos3 = broker3.open_position(symbol: "ETHUSDT", strategy_id: "test_timeout", direction: :long,
                              entry_ts: 0, entry_price: 100.0, stop_price: 95.0,
                              r_multiple_target: 3.0, horizon_bars: 2, interval_seconds: 3600)
bars3 = [
  { ts: 3600, high: 101.0, low: 99.0, close: 100.5 },  # 1 bar elapsed, no touch
  { ts: 7200, high: 103.0, low: 100.0, close: 102.0 }   # 2 bars elapsed == horizon -> timeout close at 102.0
]
broker3.process_bars_for_position!(pos3, bars3, funding_sum: 0.0)
assert(broker3.summary[:open_positions].zero?, "horizon timeout closes the position")
assert(broker3.summary[:closed_trades] == 1, "timeout produces exactly one closed trade")

# 4. Position with no touch and horizon not yet reached stays open
broker4 = PaperBroker.new(state_path: File.join(Dir.mktmpdir, "s4.json"), starting_equity_usdt: 10_000.0)
pos4 = broker4.open_position(symbol: "SOLUSDT", strategy_id: "test_stay_open", direction: :long,
                              entry_ts: 0, entry_price: 100.0, stop_price: 95.0,
                              r_multiple_target: 3.0, horizon_bars: 10, interval_seconds: 3600)
bars4 = [{ ts: 3600, high: 101.0, low: 99.0, close: 100.5 }]
broker4.process_bars_for_position!(pos4, bars4, funding_sum: 0.0)
assert(broker4.summary[:open_positions] == 1, "position stays open before horizon and without a touch")

# 5. Entry dedup: same bar timestamp is not re-processed
broker5 = PaperBroker.new(state_path: File.join(Dir.mktmpdir, "s5.json"), starting_equity_usdt: 10_000.0)
assert(broker5.last_processed_entry_ts("some_strategy").nil?, "no entry processed yet")
broker5.mark_entry_checked("some_strategy", 5000)
assert(broker5.last_processed_entry_ts("some_strategy") == 5000, "dedup timestamp recorded")

puts "\nAll PaperBroker smoke checks passed."

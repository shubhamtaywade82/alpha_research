# frozen_string_literal: true

require "json"
require "time"

# Persists paper-trading state (open positions + closed trade ledger +
# shared equity) across bot ticks. One virtual account shared by all
# strategies, matching how bin/run_finalists_backtest.rb sized the
# recommended-portfolio simulation (1% risk per trade of current equity).
#
# Dedup/resume is timestamp-based, never array-index-based — the live
# candle window rolls forward every tick, so raw indices aren't stable
# across ticks the way timestamps are.
class PaperBroker
  def initialize(state_path:, starting_equity_usdt: 10_000.0, risk_pct_per_trade: 0.01,
                 fee_bps_per_side: 4.0, slippage_bps_per_side: 2.0)
    @state_path = state_path
    @risk_pct_per_trade = risk_pct_per_trade
    @fee_bps_per_side = fee_bps_per_side
    @slippage_bps_per_side = slippage_bps_per_side
    @state = load_state(starting_equity_usdt)
  end

  def equity
    @state["equity_usdt"]
  end

  def open_position_for?(symbol, strategy_id)
    @state["open_positions"].any? { |p| p["symbol"] == symbol && p["strategy_id"] == strategy_id }
  end

  # Returns live references into @state — callers may pass these directly to
  # process_bars_for_position! so in-place mutation (last_checked_ts) persists.
  def open_positions_for(strategy_id)
    @state["open_positions"].select { |p| p["strategy_id"] == strategy_id }
  end

  def last_processed_entry_ts(strategy_id)
    @state["last_processed_entry_ts"][strategy_id]
  end

  def mark_entry_checked(strategy_id, ts)
    @state["last_processed_entry_ts"][strategy_id] = ts
  end

  def open_position(symbol:, strategy_id:, direction:, entry_ts:, entry_price:,
                     stop_price:, r_multiple_target:, horizon_bars:, interval_seconds:)
    stop_distance = (entry_price - stop_price).abs
    target_price = direction == :long ? entry_price + stop_distance * r_multiple_target \
                                       : entry_price - stop_distance * r_multiple_target

    position = {
      "id" => "#{strategy_id}-#{entry_ts}",
      "symbol" => symbol, "strategy_id" => strategy_id, "direction" => direction.to_s,
      "entry_ts" => entry_ts, "entry_price" => entry_price, "stop_price" => stop_price,
      "target_price" => target_price, "r_multiple_target" => r_multiple_target,
      "horizon_bars" => horizon_bars, "interval_seconds" => interval_seconds,
      "last_checked_ts" => entry_ts, "equity_at_entry" => equity
    }
    @state["open_positions"] << position
    log_event("OPEN  #{symbol} #{strategy_id} #{direction} @ #{entry_price.round(4)} " \
              "stop=#{stop_price.round(4)} target=#{target_price.round(4)} ts=#{Time.at(entry_ts).utc}")
    position
  end

  # bars: array of {ts:, high:, low:, close:} for this position's symbol/interval,
  # strictly newer than position's last_checked_ts, oldest -> newest.
  # funding_series_for_range: proc(start_ts, end_ts) -> summed funding rate, for cost accrual.
  def process_bars_for_position!(position, bars, funding_sum:)
    direction = position["direction"].to_sym
    closed = nil

    bars.each do |bar|
      elapsed_bars = ((bar[:ts] - position["entry_ts"]) / position["interval_seconds"].to_f).round
      if direction == :long
        if bar[:low] <= position["stop_price"]
          closed = { exit_price: position["stop_price"], exit_ts: bar[:ts], gross_r: -1.0 }
        elsif bar[:high] >= position["target_price"]
          closed = { exit_price: position["target_price"], exit_ts: bar[:ts], gross_r: position["r_multiple_target"] }
        end
      else
        if bar[:high] >= position["stop_price"]
          closed = { exit_price: position["stop_price"], exit_ts: bar[:ts], gross_r: -1.0 }
        elsif bar[:low] <= position["target_price"]
          closed = { exit_price: position["target_price"], exit_ts: bar[:ts], gross_r: position["r_multiple_target"] }
        end
      end
      break if closed

      if elapsed_bars >= position["horizon_bars"]
        stop_distance = (position["entry_price"] - position["stop_price"]).abs
        move = direction == :long ? bar[:close] - position["entry_price"] : position["entry_price"] - bar[:close]
        closed = { exit_price: bar[:close], exit_ts: bar[:ts], gross_r: (move / stop_distance).round(3) }
      end
      break if closed

      position["last_checked_ts"] = bar[:ts]
    end

    return unless closed

    close_position!(position, closed, funding_sum: funding_sum)
  end

  def save!
    File.write(@state_path, JSON.pretty_generate(@state))
  end

  def summary
    {
      equity_usdt: equity.round(2),
      open_positions: @state["open_positions"].size,
      closed_trades: @state["trade_ledger"].size,
      total_net_pnl_usdt: (equity - @state["starting_equity_usdt"]).round(2)
    }
  end

  private

  # Mirrors TradeCostModel's math (round-trip fee+slippage normalized by
  # stop distance, signed funding accrual) but takes a pre-summed funding
  # rate over the actual hold window instead of an index-based series —
  # simpler here since the caller (bin/paper_trading_bot.rb) already sums
  # funding across the live candle window by timestamp, not array index.
  def close_position!(position, closed, funding_sum:)
    stop_distance_pct = (position["entry_price"] - position["stop_price"]).abs / position["entry_price"].to_f
    round_trip_cost_pct = 2.0 * ((@fee_bps_per_side + @slippage_bps_per_side) / 10_000.0)
    direction_sign = position["direction"] == "long" ? 1.0 : -1.0
    funding_cost_pct = direction_sign * funding_sum.to_f
    net_r = stop_distance_pct.positive? ? (closed[:gross_r] - (round_trip_cost_pct + funding_cost_pct) / stop_distance_pct).round(3) : closed[:gross_r]

    pnl_usdt = position["equity_at_entry"] * @risk_pct_per_trade * net_r
    @state["equity_usdt"] += pnl_usdt

    @state["trade_ledger"] << position.merge(
      "exit_ts" => closed[:exit_ts], "exit_price" => closed[:exit_price],
      "gross_r" => closed[:gross_r], "net_r" => net_r, "pnl_usdt" => pnl_usdt.round(2),
      "equity_after" => @state["equity_usdt"].round(2)
    )
    @state["open_positions"].delete_if { |p| p["id"] == position["id"] }
    log_event("CLOSE #{position['symbol']} #{position['strategy_id']} net_R=#{net_r} pnl=$#{pnl_usdt.round(2)} equity=$#{@state['equity_usdt'].round(2)}")
  end

  def log_event(msg)
    line = "#{Time.now.utc.iso8601} #{msg}"
    puts line
    @state["event_log"] << line
    @state["event_log"].shift if @state["event_log"].size > 500
  end

  def load_state(starting_equity_usdt)
    if File.exist?(@state_path)
      JSON.parse(File.read(@state_path))
    else
      {
        "starting_equity_usdt" => starting_equity_usdt,
        "equity_usdt" => starting_equity_usdt,
        "open_positions" => [],
        "trade_ledger" => [],
        "last_processed_entry_ts" => {},
        "event_log" => []
      }
    end
  end
end

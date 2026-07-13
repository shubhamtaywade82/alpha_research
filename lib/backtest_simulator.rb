# frozen_string_literal: true

require_relative "symbol_profile"
require_relative "position_sizer"
require_relative "dynamic_risk_planner"
require_relative "move_labeler"

class BacktestSimulator
  # Represents a simulated trade execution
  TradeLog = Struct.new(
    :symbol, :direction, :entry_ts, :exit_ts, :entry_price, :stop_price,
    :exit_price, :quantity, :notional, :leverage, :gross_pnl_usdt,
    :fees_usdt, :slippage_usdt, :funding_usdt, :net_pnl_usdt, :net_pnl_inr,
    :ending_equity_usdt, :bucket_key, keyword_init: true
  )

  def initialize(starting_balance_inr:, exchange_rate_inr_usdt: 83.5, fee_bps_per_side: 4.0, slippage_bps_per_side: 2.0)
    @starting_balance_inr = starting_balance_inr
    @exchange_rate_inr_usdt = exchange_rate_inr_usdt
    @starting_balance_usdt = starting_balance_inr / exchange_rate_inr_usdt
    @fee_pct_per_side = fee_bps_per_side / 10_000.0
    @slippage_pct_per_side = slippage_bps_per_side / 10_000.0
  end

  def run(candles_by_symbol:, funding_series_by_symbol:, swings_by_symbol:, regimes_by_symbol:, feature_extractor_by_symbol:, tradeable_buckets_by_symbol:, entry_delay_bars: nil, forward_horizon_bars: nil, params_by_symbol: nil, htf_regimes_by_symbol: nil)
    params_by_symbol ||= candles_by_symbol.keys.each_with_object({}) do |sym, h|
      h[sym] = {
        stop_atr_buffer: 0.5,
        entry_delay_bars: entry_delay_bars || 1,
        forward_horizon_bars: forward_horizon_bars || 20
      }
    end

    # 1. Generate all swing signal events chronologically across all symbols
    all_events = []
    
    candles_by_symbol.each do |symbol, candles|
      profile = SymbolProfile.for(symbol)
      swings = swings_by_symbol[symbol]
      regimes = regimes_by_symbol[symbol]
      funding_series = funding_series_by_symbol[symbol]
      extractor = feature_extractor_by_symbol[symbol]
      
      sym_params = params_by_symbol[symbol] || { stop_atr_buffer: 0.5, entry_delay_bars: 1, forward_horizon_bars: 20 }
      
      labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: sym_params[:stop_atr_buffer])
      
      htf_regimes = htf_regimes_by_symbol ? htf_regimes_by_symbol[symbol] : nil
      
      events = labeler.label_signal_events(
        candles: candles, swings: swings, regimes: regimes,
        funding_series: funding_series, feature_extractor: extractor,
        entry_delay_bars: sym_params[:entry_delay_bars], forward_horizon_bars: sym_params[:forward_horizon_bars],
        htf_regimes: htf_regimes
      )
      
      events.each do |event|
        all_events << { symbol: symbol, event: event }
      end
    end
    
    # Sort events by entry timestamp
    all_events.sort_by! { |item| item[:event].entry_ts }
    
    # 2. Simulate trading chronologically
    equity_usdt = @starting_balance_usdt
    peak_equity_usdt = equity_usdt
    max_drawdown_pct = 0.0
    
    open_trades = []
    trade_logs = []
    
    all_events.each do |item|
      symbol = item[:symbol]
      event = item[:event]
      profile = SymbolProfile.for(symbol)
      sizer = PositionSizer.new(profile)
      
      # Settle any open trades that exited before this trade enters
      open_trades.reject! do |open_trade|
        if open_trade[:exit_ts] <= event.entry_ts
          pnl_info = calculate_net_pnl(
            event: open_trade[:event],
            quantity: open_trade[:quantity],
            funding_series: funding_series_by_symbol[open_trade[:symbol]],
            bar_interval_minutes: 15
          )
          
          equity_usdt += pnl_info[:net_pnl_usdt]
          peak_equity_usdt = [peak_equity_usdt, equity_usdt].max
          dd = (peak_equity_usdt - equity_usdt) / peak_equity_usdt
          max_drawdown_pct = [max_drawdown_pct, dd].max
          
          trade_logs << TradeLog.new(
            symbol: open_trade[:symbol],
            direction: open_trade[:event].direction,
            entry_ts: open_trade[:event].entry_ts,
            exit_ts: open_trade[:exit_ts],
            entry_price: open_trade[:event].entry_price,
            stop_price: open_trade[:event].stop_price,
            exit_price: open_trade[:event].exit_price,
            quantity: open_trade[:quantity],
            notional: open_trade[:notional],
            leverage: open_trade[:leverage],
            gross_pnl_usdt: pnl_info[:gross_pnl_usdt],
            fees_usdt: pnl_info[:fees_usdt],
            slippage_usdt: pnl_info[:slippage_usdt],
            funding_usdt: pnl_info[:funding_usdt],
            net_pnl_usdt: pnl_info[:net_pnl_usdt],
            net_pnl_inr: pnl_info[:net_pnl_usdt] * @exchange_rate_inr_usdt,
            ending_equity_usdt: equity_usdt,
            bucket_key: open_trade[:bucket_key]
          )
          true # delete from open_trades
        else
          false
        end
      end
      
      # If htf_regimes_by_symbol is provided, enforce macro-trend alignment
      if htf_regimes_by_symbol && htf_regimes_by_symbol[symbol]
        htf_reg = htf_regimes_by_symbol[symbol][event.entry_index]
        if htf_reg
          if htf_reg.state == :trending_bull && event.direction != :long
            next
          elsif htf_reg.state == :trending_bear && event.direction != :short
            next
          end
        end
      end

      # Check if the bucket for this event is tradeable for this symbol
      bucket_key = event.context[:regime_state]
      tradeable_info = tradeable_buckets_by_symbol[symbol][bucket_key]
      next if tradeable_info.nil?
      
      # Check if event matches the dominant direction
      next if event.direction != tradeable_info[:direction]
      
      # Size the position
      risk_pct = tradeable_info[:plan].risk_pct
      
      # Limit total open notional to prevent margin call on overlapping trades
      current_open_notional = open_trades.sum { |t| t[:notional] }
      max_allowed_new_notional = (equity_usdt * profile.max_leverage) - current_open_notional
      next if max_allowed_new_notional <= 0
      
      begin
        sizing = sizer.size(
          account_equity: equity_usdt,
          entry_price: event.entry_price,
          stop_price: event.stop_price,
          risk_pct: risk_pct,
          direction: event.direction
        )
        
        quantity = sizing.quantity
        notional = sizing.notional
        if notional > max_allowed_new_notional
          notional = max_allowed_new_notional
          quantity = notional / event.entry_price
        end
        
        next if quantity <= 0
        
        exit_bar_ts = event.exit_index && candles_by_symbol[symbol][event.exit_index] ? candles_by_symbol[symbol][event.exit_index][:ts] : event.entry_ts
        
        open_trades << {
          symbol: symbol,
          event: event,
          quantity: quantity.round(6),
          notional: notional.round(2),
          leverage: sizing.leverage_used,
          exit_ts: exit_bar_ts,
          bucket_key: bucket_key
        }
      rescue StandardError
        # skip if sizing fails
      end
    end
    
    # Settle any remaining open trades at the end of the simulation
    open_trades.each do |open_trade|
      pnl_info = calculate_net_pnl(
        event: open_trade[:event],
        quantity: open_trade[:quantity],
        funding_series: funding_series_by_symbol[open_trade[:symbol]],
        bar_interval_minutes: 15
      )
      
      equity_usdt += pnl_info[:net_pnl_usdt]
      peak_equity_usdt = [peak_equity_usdt, equity_usdt].max
      dd = (peak_equity_usdt - equity_usdt) / peak_equity_usdt
      max_drawdown_pct = [max_drawdown_pct, dd].max
      
      trade_logs << TradeLog.new(
        symbol: open_trade[:symbol],
        direction: open_trade[:event].direction,
        entry_ts: open_trade[:event].entry_ts,
        exit_ts: open_trade[:exit_ts],
        entry_price: open_trade[:event].entry_price,
        stop_price: open_trade[:event].stop_price,
        exit_price: open_trade[:event].exit_price,
        quantity: open_trade[:quantity],
        notional: open_trade[:notional],
        leverage: open_trade[:leverage],
        gross_pnl_usdt: pnl_info[:gross_pnl_usdt],
        fees_usdt: pnl_info[:fees_usdt],
        slippage_usdt: pnl_info[:slippage_usdt],
        funding_usdt: pnl_info[:funding_usdt],
        net_pnl_usdt: pnl_info[:net_pnl_usdt],
        net_pnl_inr: pnl_info[:net_pnl_usdt] * @exchange_rate_inr_usdt,
        ending_equity_usdt: equity_usdt,
        bucket_key: open_trade[:bucket_key]
      )
    end
    
    net_profit_usdt = equity_usdt - @starting_balance_usdt
    
    {
      starting_balance_inr: @starting_balance_inr,
      starting_balance_usdt: @starting_balance_usdt,
      final_balance_usdt: equity_usdt,
      final_balance_inr: equity_usdt * @exchange_rate_inr_usdt,
      net_profit_usdt: net_profit_usdt,
      net_profit_inr: net_profit_usdt * @exchange_rate_inr_usdt,
      net_profit_pct: (net_profit_usdt / @starting_balance_usdt) * 100.0,
      max_drawdown_pct: max_drawdown_pct * 100.0,
      total_trades: trade_logs.size,
      win_rate: trade_logs.empty? ? 0.0 : trade_logs.count { |t| t.net_pnl_usdt.positive? } / trade_logs.size.to_f,
      trades: trade_logs
    }
  end

  private

  def calculate_net_pnl(event:, quantity:, funding_series:, bar_interval_minutes:)
    entry_notional = quantity * event.entry_price
    exit_notional = quantity * event.exit_price
    
    gross_pnl_usdt =
      if event.direction == :long
        exit_notional - entry_notional
      else
        entry_notional - exit_notional
      end
      
    fees_usdt = (entry_notional + exit_notional) * @fee_pct_per_side
    slippage_usdt = (entry_notional + exit_notional) * @slippage_pct_per_side
    
    bars_per_funding_period = (8.0 * 60.0) / bar_interval_minutes
    funding_proration = 1.0 / bars_per_funding_period
    
    accrued_rate = 0.0
    if funding_series && event.entry_index + 1 <= event.exit_index
      accrued_rate = funding_series[event.entry_index + 1..event.exit_index].compact.sum.to_f * funding_proration
    end
    
    funding_cost_pct = event.direction == :long ? accrued_rate : -accrued_rate
    funding_usdt = entry_notional * funding_cost_pct
    
    net_pnl_usdt = gross_pnl_usdt - fees_usdt - slippage_usdt - funding_usdt
    
    {
      gross_pnl_usdt: gross_pnl_usdt,
      fees_usdt: fees_usdt,
      slippage_usdt: slippage_usdt,
      funding_usdt: funding_usdt,
      net_pnl_usdt: net_pnl_usdt
    }
  end
end

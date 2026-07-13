# frozen_string_literal: true

# Converts gross R-multiples into net R-multiples after explicit trading
# frictions. Costs are modeled in percentage-of-notional terms, then
# normalized by the trade's stop distance to express them in R units.
#
# Funding rates from Binance are 8-hour rates; the per-bar forward-filled
# series is prorated over the bar interval to approximate accrual across the
# trade's holding window.
class TradeCostModel
  def initialize(fee_bps_per_side:, slippage_bps_per_side:, bar_interval_minutes:, funding_period_hours: 8.0)
    @fee_pct_per_side = fee_bps_per_side / 10_000.0
    @slippage_pct_per_side = slippage_bps_per_side / 10_000.0
    bars_per_funding_period = (funding_period_hours * 60.0) / bar_interval_minutes
    @funding_proration = bars_per_funding_period.positive? ? (1.0 / bars_per_funding_period) : 0.0
  end

  def net_r_for_event(event:, funding_series:)
    stop_distance_pct = stop_distance_pct(event.entry_price, (event.entry_price - event.stop_price).abs)
    return event.r_multiple if stop_distance_pct <= 0

    total_cost_pct = round_trip_cost_pct + signed_funding_cost_pct(
      direction: event.direction,
      funding_series: funding_series,
      start_index: event.entry_index + 1,
      end_index: event.exit_index
    )

    (event.r_multiple - (total_cost_pct / stop_distance_pct)).round(3)
  end

  def net_r_for_baseline(sample:, direction:, funding_series:)
    gross_r = direction == :short ? sample.short_r_multiple : sample.long_r_multiple
    exit_index = direction == :short ? sample.short_exit_index : sample.long_exit_index
    stop_distance_pct = stop_distance_pct(sample.entry_price, sample.stop_distance)
    return gross_r if stop_distance_pct <= 0

    total_cost_pct = round_trip_cost_pct + signed_funding_cost_pct(
      direction: direction,
      funding_series: funding_series,
      start_index: sample.index + 1,
      end_index: exit_index
    )

    (gross_r - (total_cost_pct / stop_distance_pct)).round(3)
  end

  private

  def round_trip_cost_pct
    2.0 * (@fee_pct_per_side + @slippage_pct_per_side)
  end

  def signed_funding_cost_pct(direction:, funding_series:, start_index:, end_index:)
    return 0.0 if funding_series.nil? || funding_series.empty? || end_index < start_index

    accrued_rate = funding_series[start_index..end_index].sum.to_f * @funding_proration
    direction == :long ? accrued_rate : -accrued_rate
  end

  def stop_distance_pct(entry_price, stop_distance)
    return 0.0 if entry_price.nil? || entry_price.zero? || stop_distance.nil?

    stop_distance / entry_price.to_f
  end
end

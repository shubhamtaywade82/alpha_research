# frozen_string_literal: true

# Sizes a position given account equity, entry price, and structural stop
# distance, enforcing two hard caps simultaneously:
#   1. Never exceed profile.max_leverage (which itself never exceeds the
#      account-level 10x ceiling).
#   2. Never let the position's liquidation price sit closer than
#      profile.liquidation_buffer_pct from entry.
#
# Whichever constraint produces the SMALLER position size wins. This
# implements "no closing in negative PnL" as a sizing-time risk control,
# not a literal stop-loss disable.
class PositionSizer
  Sizing = Struct.new(
    :quantity, :notional, :leverage_used, :stop_price,
    :liquidation_price, :risk_amount, :r_multiple_target_price,
    :capped_by, keyword_init: true
  )

  MAX_ACCOUNT_LEVERAGE = 10

  def initialize(profile)
    @profile = profile
    raise ArgumentError, "profile.max_leverage exceeds account ceiling" \
      if profile.max_leverage > MAX_ACCOUNT_LEVERAGE
  end

  # account_equity: USDT
  # entry_price: proposed entry
  # stop_price: structural invalidation price (from SMC structure / ATR stop)
  # risk_pct: fraction of equity risked on this trade (e.g. 0.01 = 1%)
  # direction: :long or :short
  def size(account_equity:, entry_price:, stop_price:, risk_pct:, direction:)
    stop_distance = (entry_price - stop_price).abs
    raise ArgumentError, "stop_distance must be positive" if stop_distance <= 0

    risk_amount = account_equity * risk_pct

    # Constraint 1: risk-based sizing
    qty_from_risk = risk_amount / stop_distance

    # Constraint 2: max leverage cap
    max_notional_by_leverage = account_equity * @profile.max_leverage
    qty_from_leverage_cap = max_notional_by_leverage / entry_price

    # Constraint 3: liquidation buffer — approximate liquidation distance
    # as entry_price / leverage (isolated margin, simplified; exchange's
    # actual liq engine includes fees/funding, treat this as a floor check)
    qty_candidates = { risk: qty_from_risk, leverage_cap: qty_from_leverage_cap }
    binding_constraint, quantity = qty_candidates.min_by { |_, q| q }

    notional = quantity * entry_price
    leverage_used = notional / account_equity
    approx_liq_distance_pct = 1.0 / leverage_used

    if approx_liq_distance_pct < @profile.liquidation_buffer_pct
      # Re-cap by liquidation buffer requirement
      max_leverage_for_buffer = 1.0 / @profile.liquidation_buffer_pct
      quantity = (account_equity * max_leverage_for_buffer) / entry_price
      notional = quantity * entry_price
      leverage_used = notional / account_equity
      binding_constraint = :liquidation_buffer
    end

    liquidation_price =
      direction == :long ? entry_price * (1 - 1.0 / leverage_used) : entry_price * (1 + 1.0 / leverage_used)

    r_target_price =
      if direction == :long
        entry_price + stop_distance * @profile.r_multiple_target
      else
        entry_price - stop_distance * @profile.r_multiple_target
      end

    Sizing.new(
      quantity: quantity.round(6),
      notional: notional.round(2),
      leverage_used: leverage_used.round(2),
      stop_price: stop_price,
      liquidation_price: liquidation_price.round(4),
      risk_amount: risk_amount.round(2),
      r_multiple_target_price: r_target_price.round(4),
      capped_by: binding_constraint
    )
  end
end

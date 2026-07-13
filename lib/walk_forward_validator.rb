# frozen_string_literal: true

# Nested walk-forward validator with purge/embargo gaps between train and
# test windows. This is the mandatory OOS gate every candidate must clear
# before being trusted — no candidate here has cleared it yet.
#
# Usage pattern: split candles into N folds, evaluate the strategy signal
# stream on the OOS (test) segment of each fold only, aggregate trade
# outcomes across folds. Training here doesn't fit model weights (the
# strategy is rule-based) — it's used to sweep/select symbol_profile
# parameters on train, then confirm out-of-sample on test, per fold.
class WalkForwardValidator
  Fold = Struct.new(:train_range, :embargo_range, :test_range, keyword_init: true)

  # total_bars: length of the candle series
  # n_folds: number of walk-forward folds
  # embargo_bars: gap between train and test to prevent lookahead leakage
  #   from indicator lookback windows spanning the boundary
  def self.build_folds(total_bars:, n_folds:, embargo_bars:)
    fold_size = total_bars / n_folds
    (0...n_folds).map do |i|
      test_start = i * fold_size
      test_end = [(i + 1) * fold_size, total_bars].min
      train_end = test_start - embargo_bars
      train_start = 0

      next nil if train_end <= train_start # not enough history for this fold

      Fold.new(
        train_range: (train_start...train_end),
        embargo_range: (train_end...test_start),
        test_range: (test_start...test_end)
      )
    end.compact
  end

  # results_per_fold: caller supplies a block that runs the strategy on
  # the fold's test_range and returns an Array of trade outcome hashes:
  #   { r_multiple:, direction:, entry_ts:, exit_ts:, reason: }
  def self.run(candles:, n_folds:, embargo_bars:)
    folds = build_folds(total_bars: candles.size, n_folds: n_folds, embargo_bars: embargo_bars)

    fold_results = folds.map do |fold|
      trades = yield(fold)
      {
        fold: fold,
        trade_count: trades.size,
        win_rate: win_rate(trades),
        expectancy_r: expectancy(trades),
        max_drawdown_r: max_drawdown(trades)
      }
    end

    {
      folds: fold_results,
      aggregate: aggregate_summary(fold_results)
    }
  end

  def self.win_rate(trades)
    return nil if trades.empty?

    trades.count { |t| t[:r_multiple].positive? } / trades.size.to_f
  end

  def self.expectancy(trades)
    return nil if trades.empty?

    trades.sum { |t| t[:r_multiple] } / trades.size.to_f
  end

  def self.max_drawdown(trades)
    return nil if trades.empty?

    cumulative = 0.0
    peak = 0.0
    max_dd = 0.0
    trades.each do |t|
      cumulative += t[:r_multiple]
      peak = [peak, cumulative].max
      max_dd = [max_dd, peak - cumulative].max
    end
    max_dd
  end

  def self.aggregate_summary(fold_results)
    valid = fold_results.reject { |f| f[:trade_count].zero? }
    return { note: "no trades generated across any fold" } if valid.empty?

    {
      total_folds: fold_results.size,
      folds_with_trades: valid.size,
      mean_expectancy_r: valid.sum { |f| f[:expectancy_r] } / valid.size.to_f,
      mean_win_rate: valid.sum { |f| f[:win_rate] } / valid.size.to_f,
      worst_fold_drawdown_r: valid.map { |f| f[:max_drawdown_r] }.max
    }
  end
end

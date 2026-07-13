# frozen_string_literal: true

# Splits a chronological candle series into a research slice (first 80%,
# used for all discovery/calibration/sweeping) and a holdout slice (final
# 20%, touched only once by bin/run_holdout_eval.rb).
module DataWindow
  module_function

  def research_slice(candles)
    candles[0...research_cutoff(candles.size)]
  end

  def holdout_slice(candles)
    candles[research_cutoff(candles.size)..]
  end

  def research_cutoff(size)
    (size * 0.8).to_i
  end
end

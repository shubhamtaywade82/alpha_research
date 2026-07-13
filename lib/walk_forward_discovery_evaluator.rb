# frozen_string_literal: true

require_relative "regime_classifier"
require_relative "swing_point_detector"
require_relative "context_feature_extractor"
require_relative "move_labeler"
require_relative "signature_analyzer"
require_relative "dynamic_risk_planner"
require_relative "walk_forward_validator"

# Walk-forward evaluation of the discovery pipeline:
# 1. discover tradeable regime buckets on each train fold
# 2. trade only those buckets on the out-of-sample test fold
# 3. compare net trade expectancy against the unconditional baseline in the
#    same OOS buckets and dominant directions selected from train
class WalkForwardDiscoveryEvaluator
  BucketAggregate = Struct.new(
    :bucket_key, :direction, :trade_count, :gross_expectancy_r, :net_expectancy_r,
    :baseline_net_expectancy_r, :alpha_net_r, :win_rate, keyword_init: true
  )

  FoldSummary = Struct.new(
    :fold, :tradeable_buckets, :trade_count, :gross_expectancy_r, :net_expectancy_r,
    :baseline_net_expectancy_r, :alpha_net_r, :win_rate, :bucket_aggregates,
    keyword_init: true
  )

  Trade = Struct.new(
    :bucket_key, :direction, :entry_ts, :exit_ts, :gross_r, :net_r, keyword_init: true
  )

  def initialize(profile:, cost_model:, entry_delay_bars:, forward_horizon_bars: 20,
                 baseline_stride: 5, min_move_atr_multiple: 1.5,
                 bucket_by: ->(ctx) { ctx[:regime_state] }, htf_regimes: nil)
    @profile = profile
    @cost_model = cost_model
    @entry_delay_bars = entry_delay_bars
    @forward_horizon_bars = forward_horizon_bars
    @baseline_stride = baseline_stride
    @min_move_atr_multiple = min_move_atr_multiple
    @bucket_by = bucket_by
    @htf_regimes = htf_regimes
  end

  def evaluate(candles:, funding_series:, n_folds:, embargo_bars:)
    regimes = RegimeClassifier.new(@profile).classify(candles)
    swings = SwingPointDetector.new(min_move_atr_multiple: @min_move_atr_multiple).detect(candles)
    extractor = ContextFeatureExtractor.new(@profile)
    labeler = MoveLabeler.new(r_multiple_target: @profile.r_multiple_target)

    events = labeler.label_signal_events(
      candles: candles, swings: swings, regimes: regimes, funding_series: funding_series,
      feature_extractor: extractor, entry_delay_bars: @entry_delay_bars,
      forward_horizon_bars: @forward_horizon_bars, htf_regimes: @htf_regimes
    )
    baselines = labeler.label_baseline_samples(
      candles: candles, regimes: regimes, funding_series: funding_series,
      feature_extractor: extractor, forward_horizon_bars: @forward_horizon_bars,
      stride: @baseline_stride, htf_regimes: @htf_regimes
    )

    folds = WalkForwardValidator.build_folds(
      total_bars: candles.size, n_folds: n_folds, embargo_bars: embargo_bars
    )
    fold_summaries = folds.map do |fold|
      summarize_fold(fold: fold, events: events, baselines: baselines, candles: candles, funding_series: funding_series)
    end

    { folds: fold_summaries, aggregate: aggregate(fold_summaries) }
  end

  private

  def summarize_fold(fold:, events:, baselines:, candles:, funding_series:)
    train_events = select_events(events, fold.train_range)
    train_baselines = select_baselines(baselines, fold.train_range)
    train_buckets = SignatureAnalyzer.analyze(
      swing_events: train_events,
      baseline_samples: train_baselines,
      bucket_by: @bucket_by
    )

    tradeable = train_buckets.filter_map do |bucket|
      plan = DynamicRiskPlanner.plan(bucket_stats: bucket)
      next unless plan.tradeable

      dominant_direction = dominant_direction_for(train_events, bucket.bucket_key)
      next if dominant_direction.nil?

      [bucket.bucket_key, { plan: plan, direction: dominant_direction }]
    end.to_h

    test_events = select_events(events, fold.test_range)
    selected_events = test_events.select { |event| tradeable.key?(bucket_for(event.context)) }
    bucket_trade_net = Hash.new { |h, k| h[k] = [] }
    bucket_trade_gross = Hash.new { |h, k| h[k] = [] }
    trades = selected_events.map do |event|
      net_r = @cost_model.net_r_for_event(event: event, funding_series: funding_series)
      bucket_key = bucket_for(event.context)
      bucket_trade_net[bucket_key] << net_r
      bucket_trade_gross[bucket_key] << event.r_multiple
      Trade.new(
        bucket_key: bucket_key,
        direction: event.direction,
        entry_ts: candles[event.entry_index][:ts],
        exit_ts: candles[event.exit_index][:ts],
        gross_r: event.r_multiple,
        net_r: net_r
      )
    end

    test_baselines = select_baselines(baselines, fold.test_range)
    bucket_baseline_net = Hash.new { |h, k| h[k] = [] }
    baseline_net_rs = test_baselines.filter_map do |sample|
      bucket_key = bucket_for(sample.context)
      bucket = tradeable[bucket_key]
      next if bucket.nil?

      value = @cost_model.net_r_for_baseline(
        sample: sample, direction: bucket[:direction], funding_series: funding_series
      )
      bucket_baseline_net[bucket_key] << value
      value
    end

    gross_expectancy = mean(trades.map(&:gross_r))
    net_expectancy = mean(trades.map(&:net_r))
    baseline_expectancy = mean(baseline_net_rs)

    FoldSummary.new(
      fold: fold,
      tradeable_buckets: tradeable.transform_values { |v| { direction: v[:direction], reason: v[:plan].reason } },
      trade_count: trades.size,
      gross_expectancy_r: gross_expectancy&.round(3),
      net_expectancy_r: net_expectancy&.round(3),
      baseline_net_expectancy_r: baseline_expectancy&.round(3),
      alpha_net_r: (net_expectancy && baseline_expectancy ? (net_expectancy - baseline_expectancy).round(3) : nil),
      win_rate: win_rate(trades),
      bucket_aggregates: summarize_buckets(
        tradeable: tradeable,
        bucket_trade_gross: bucket_trade_gross,
        bucket_trade_net: bucket_trade_net,
        bucket_baseline_net: bucket_baseline_net
      )
    )
  end

  def select_events(events, range)
    events.select do |event|
      range.cover?(event.entry_index) && event.exit_index < range.end
    end
  end

  def select_baselines(baselines, range)
    baselines.select do |sample|
      range.cover?(sample.index) &&
        sample.long_exit_index < range.end &&
        sample.short_exit_index < range.end
    end
  end

  def dominant_direction_for(events, bucket_key)
    bucket_events = events.select { |event| bucket_for(event.context) == bucket_key }
    bucket_events.group_by(&:direction).max_by { |_, vals| vals.size }&.first
  end

  def aggregate(folds)
    valid = folds.reject { |fold| fold.trade_count.zero? }
    return { note: "no OOS trades generated across any fold" } if valid.empty?

    bucket_trade_gross = Hash.new { |h, k| h[k] = [] }
    bucket_trade_net = Hash.new { |h, k| h[k] = [] }
    bucket_baseline_net = Hash.new { |h, k| h[k] = [] }
    bucket_direction = {}
    valid.each do |fold|
      fold.bucket_aggregates.each do |bucket|
        bucket_trade_gross[bucket.bucket_key] += bucket.instance_variable_get(:@gross_values) if bucket.instance_variable_defined?(:@gross_values)
        bucket_trade_net[bucket.bucket_key] += bucket.instance_variable_get(:@net_values) if bucket.instance_variable_defined?(:@net_values)
        bucket_baseline_net[bucket.bucket_key] += bucket.instance_variable_get(:@baseline_values) if bucket.instance_variable_defined?(:@baseline_values)
        bucket_direction[bucket.bucket_key] ||= bucket.direction
      end
    end

    {
      total_folds: folds.size,
      folds_with_trades: valid.size,
      total_trades: valid.sum(&:trade_count),
      mean_gross_expectancy_r: mean(valid.map(&:gross_expectancy_r))&.round(3),
      mean_net_expectancy_r: mean(valid.map(&:net_expectancy_r))&.round(3),
      mean_baseline_net_expectancy_r: mean(valid.map(&:baseline_net_expectancy_r).compact)&.round(3),
      mean_alpha_net_r: mean(valid.map(&:alpha_net_r).compact)&.round(3),
      mean_win_rate: mean(valid.map(&:win_rate))&.round(3),
      bucket_aggregates: aggregate_buckets(
        bucket_direction: bucket_direction,
        bucket_trade_gross: bucket_trade_gross,
        bucket_trade_net: bucket_trade_net,
        bucket_baseline_net: bucket_baseline_net
      )
    }
  end

  def summarize_buckets(tradeable:, bucket_trade_gross:, bucket_trade_net:, bucket_baseline_net:)
    tradeable.map do |bucket_key, meta|
      gross_values = bucket_trade_gross[bucket_key]
      net_values = bucket_trade_net[bucket_key]
      baseline_values = bucket_baseline_net[bucket_key]
      bucket = BucketAggregate.new(
        bucket_key: bucket_key,
        direction: meta[:direction],
        trade_count: net_values.size,
        gross_expectancy_r: mean(gross_values)&.round(3),
        net_expectancy_r: mean(net_values)&.round(3),
        baseline_net_expectancy_r: mean(baseline_values)&.round(3),
        alpha_net_r: bucket_alpha(net_values, baseline_values),
        win_rate: bucket_win_rate(net_values)
      )
      bucket.instance_variable_set(:@gross_values, gross_values)
      bucket.instance_variable_set(:@net_values, net_values)
      bucket.instance_variable_set(:@baseline_values, baseline_values)
      bucket
    end
  end

  def aggregate_buckets(bucket_direction:, bucket_trade_gross:, bucket_trade_net:, bucket_baseline_net:)
    bucket_direction.keys.map do |bucket_key|
      gross_values = bucket_trade_gross[bucket_key]
      net_values = bucket_trade_net[bucket_key]
      baseline_values = bucket_baseline_net[bucket_key]
      BucketAggregate.new(
        bucket_key: bucket_key,
        direction: bucket_direction[bucket_key],
        trade_count: net_values.size,
        gross_expectancy_r: mean(gross_values)&.round(3),
        net_expectancy_r: mean(net_values)&.round(3),
        baseline_net_expectancy_r: mean(baseline_values)&.round(3),
        alpha_net_r: bucket_alpha(net_values, baseline_values),
        win_rate: bucket_win_rate(net_values)
      )
    end.sort_by { |bucket| [-(bucket.alpha_net_r || -Float::INFINITY), -bucket.trade_count] }
  end

  def bucket_for(context)
    @bucket_by.call(context)
  end

  def bucket_alpha(net_values, baseline_values)
    net = mean(net_values)
    baseline = mean(baseline_values)
    return nil if net.nil? || baseline.nil?

    (net - baseline).round(3)
  end

  def bucket_win_rate(net_values)
    return nil if net_values.empty?

    (net_values.count(&:positive?) / net_values.size.to_f).round(3)
  end

  def mean(values)
    vals = values.compact
    return nil if vals.empty?

    vals.sum / vals.size.to_f
  end

  def win_rate(trades)
    return nil if trades.empty?

    (trades.count { |trade| trade.net_r.positive? } / trades.size.to_f).round(3)
  end
end

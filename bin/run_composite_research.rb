#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

root = File.expand_path("..", __dir__)
require_relative "../lib/binance_data_loader"
require_relative "../lib/symbol_profile"
require_relative "../lib/regime_classifier"
require_relative "../lib/swing_point_detector"
require_relative "../lib/context_feature_extractor"
require_relative "../lib/move_labeler"
require_relative "../lib/signature_analyzer"
require_relative "../lib/dynamic_risk_planner"
require_relative "../lib/walk_forward_validator"
require_relative "../lib/backtest_simulator"
require_relative "../lib/candle_resampler"

SYMBOLS = %w[SOLUSDT ETHUSDT XRPUSDT].freeze
INTERVAL = "15m"
DAYS_BACK = 90
WALK_FORWARD_FOLDS = 6
EMBARGO_BARS = 5
CACHE_DIR = File.join(root, "data", "cache")

STARTING_BALANCE_INR = 100_000.0
EXCHANGE_RATE = 83.5 # INR/USDT

# 1. Load data and resample to 1h
candles_by_symbol = {}
funding_series_by_symbol = {}
regimes_by_symbol = {}
aligned_4h_regimes_by_symbol = {}
swings_by_symbol = {}
feature_extractor_by_symbol = {}

puts "======================================================================"
puts "COMPOSITE MARKET CONTEXT RESEARCH ENGINE"
puts "======================================================================"

SYMBOLS.each do |symbol|
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_#{DAYS_BACK}d.json")))
  
  candles_15m = BinanceDataLoader.klines_to_candles(raw_klines)
  candles = CandleResampler.resample_candles(candles_15m, 4) # 1H
  
  funding_series = BinanceDataLoader.align_funding_series(candles, raw_funding)
  profile = SymbolProfile.for(symbol)
  
  regimes = RegimeClassifier.new(profile).classify(candles)
  swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
  extractor = ContextFeatureExtractor.new(profile)
  
  # Warm up caches
  closes = candles.map { |c| c[:close] }
  extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
  extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)
  
  # Compute and cache RSI
  rsi_series = Indicators.rsi(candles, 14)
  extractor.rsi_cache = rsi_series
  
  # Align 4h regimes for MTF gating (1h * 4 = 4h)
  htf_factor = 4
  htf_candles = CandleResampler.resample_candles(candles, htf_factor)
  htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
  aligned_4h_regimes = CandleResampler.align_higher_regimes(
    lower_candles: candles,
    higher_candles: htf_candles,
    higher_regimes: htf_regimes
  )
  
  candles_by_symbol[symbol] = candles
  funding_series_by_symbol[symbol] = funding_series
  regimes_by_symbol[symbol] = regimes
  aligned_4h_regimes_by_symbol[symbol] = aligned_4h_regimes
  swings_by_symbol[symbol] = swings
  feature_extractor_by_symbol[symbol] = extractor
  
  puts "#{symbol}: 1H Resampled Candles loaded."
end

# Build folds
total_bars = candles_by_symbol[SYMBOLS.first].size
folds = WalkForwardValidator.build_folds(total_bars: total_bars, n_folds: WALK_FORWARD_FOLDS, embargo_bars: EMBARGO_BARS)

# Define our 6 Post-Entry Gating Filters
filters = {
  regime: {
    name: "Regime Only (No filter)",
    filter_lambda: ->(event, aligned_4h) { true }
  },
  volume_sweep: {
    name: "Volume Sweep (vol_z > 1.0)",
    filter_lambda: ->(event, aligned_4h) { event.context[:volume_zscore] && event.context[:volume_zscore] > 1.0 }
  },
  vol_squeeze: {
    name: "Bollinger Squeeze (bb_width < 0.05)",
    filter_lambda: ->(event, aligned_4h) { event.context[:bb_width] && event.context[:bb_width] < 0.05 }
  },
  ema_stretch: {
    name: "EMA Stretch Reversion",
    filter_lambda: ->(event, aligned_4h) { event.context[:dist_from_ema_slow_pct] && event.context[:dist_from_ema_slow_pct].abs > 0.01 }
  },
  rsi_filter: {
    name: "RSI Gating (L<45, S>55)",
    filter_lambda: ->(event, aligned_4h) {
      rsi = event.context[:rsi]
      return true if rsi.nil?
      event.direction == :long ? rsi < 45 : rsi > 55
    }
  },
  mtf_align: {
    name: "4H MTF Trend Aligned",
    filter_lambda: ->(event, aligned_4h) {
      htf_reg = aligned_4h ? aligned_4h[event.entry_index] : nil
      if htf_reg
        if htf_reg.state == :trending_bull && event.direction != :long
          false
        elsif htf_reg.state == :trending_bear && event.direction != :short
          false
        else
          true
        end
      else
        true
      end
    }
  }
}

# Parameters used for research
STOP_ATR_BUFFER = 1.0
ENTRY_DELAY_BARS = 1
FORWARD_HORIZON_BARS = 20

scenarios = {}
filters.each do |part_key, cfg|
  scenarios[part_key] = {
    name: cfg[:name],
    compounded_balance_usdt: STARTING_BALANCE_INR / EXCHANGE_RATE,
    trades: [],
    equity_curve: []
  }
end

# Modifying BacktestSimulator on the fly for our custom filter sweep
# We subclass BacktestSimulator to inject our filter hook
class GatedSimulator < BacktestSimulator
  def run_with_filter(candles_by_symbol:, funding_series_by_symbol:, swings_by_symbol:, regimes_by_symbol:, feature_extractor_by_symbol:, tradeable_buckets_by_symbol:, params_by_symbol:, aligned_4h_by_symbol:, filter_proc:)
    
    # 1. Generate all swing signal events chronologically
    all_events = []
    candles_by_symbol.each do |symbol, candles|
      profile = SymbolProfile.for(symbol)
      swings = swings_by_symbol[symbol]
      regimes = regimes_by_symbol[symbol]
      funding_series = funding_series_by_symbol[symbol]
      extractor = feature_extractor_by_symbol[symbol]
      sym_params = params_by_symbol[symbol]
      
      labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: sym_params[:stop_atr_buffer])
      events = labeler.label_signal_events(
        candles: candles, swings: swings, regimes: regimes,
        funding_series: funding_series, feature_extractor: extractor,
        entry_delay_bars: sym_params[:entry_delay_bars], forward_horizon_bars: sym_params[:forward_horizon_bars]
      )
      
      events.each do |event|
        all_events << { symbol: symbol, event: event }
      end
    end
    
    all_events.sort_by! { |item| item[:event].entry_ts }
    
    # 2. Simulate trading
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
      
      # Settle open trades
      open_trades.reject! do |open_trade|
        if open_trade[:exit_ts] <= event.entry_ts
          pnl_info = calculate_net_pnl(
            event: open_trade[:event],
            quantity: open_trade[:quantity],
            funding_series: funding_series_by_symbol[open_trade[:symbol]],
            bar_interval_minutes: 60 # 1H candles
          )
          
          equity_usdt += pnl_info[:net_pnl_usdt]
          peak_equity_usdt = [peak_equity_usdt, equity_usdt].max
          dd = (peak_equity_usdt - equity_usdt) / peak_equity_usdt
          max_drawdown_pct = [max_drawdown_pct, dd].max
          
          trade_logs << BacktestSimulator::TradeLog.new(
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
          true
        else
          false
        end
      end
      
      # Check if regime is tradeable
      bucket_key = event.context[:regime_state]
      tradeable_info = tradeable_buckets_by_symbol[symbol][bucket_key]
      next if tradeable_info.nil?
      next if event.direction != tradeable_info[:direction]
      
      # APPLY POST-ENTRY FILTER HOOK
      aligned_4h = aligned_4h_by_symbol ? aligned_4h_by_symbol[symbol] : nil
      next unless filter_proc.call(event, aligned_4h)
      
      # Size position
      risk_pct = tradeable_info[:plan].risk_pct
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
      end
    end
    
    # Settle remaining
    open_trades.each do |open_trade|
      pnl_info = calculate_net_pnl(
        event: open_trade[:event],
        quantity: open_trade[:quantity],
        funding_series: funding_series_by_symbol[open_trade[:symbol]],
        bar_interval_minutes: 60
      )
      
      equity_usdt += pnl_info[:net_pnl_usdt]
      peak_equity_usdt = [peak_equity_usdt, equity_usdt].max
      dd = (peak_equity_usdt - equity_usdt) / peak_equity_usdt
      max_drawdown_pct = [max_drawdown_pct, dd].max
      
      trade_logs << BacktestSimulator::TradeLog.new(
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
      net_profit_usdt: net_profit_usdt,
      max_drawdown_pct: max_drawdown_pct * 100.0,
      trades: trade_logs
    }
  end
end

puts "\nEvaluating post-entry filters across walk-forward folds..."

folds.each_with_index do |fold, fold_idx|
  puts "  Fold #{fold_idx + 1}/#{WALK_FORWARD_FOLDS}..."
  
  test_start_ts = candles_by_symbol[SYMBOLS.first][fold.test_range.first][:ts]
  test_end_ts = candles_by_symbol[SYMBOLS.first][fold.test_range.max][:ts]
  
  # Precompute training tradeable buckets based on REGIME state only (to avoid data sparsity)
  tradeable_buckets_by_symbol = {}
  SYMBOLS.each do |symbol|
    candles = candles_by_symbol[symbol]
    swings = swings_by_symbol[symbol]
    regimes = regimes_by_symbol[symbol]
    funding_series = funding_series_by_symbol[symbol]
    extractor = feature_extractor_by_symbol[symbol]
    profile = SymbolProfile.for(symbol)
    
    labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: STOP_ATR_BUFFER)
    
    train_events = labeler.label_signal_events(
      candles: candles[0..fold.train_range.end],
      swings: swings.select { |s| fold.train_range.cover?(s.index) },
      regimes: regimes[0..fold.train_range.end],
      funding_series: funding_series[0..fold.train_range.end],
      feature_extractor: extractor,
      entry_delay_bars: ENTRY_DELAY_BARS,
      forward_horizon_bars: FORWARD_HORIZON_BARS
    )
    
    train_baselines = labeler.label_baseline_samples(
      candles: candles[0..fold.train_range.end],
      regimes: regimes[0..fold.train_range.end],
      funding_series: funding_series[0..fold.train_range.end],
      feature_extractor: extractor,
      forward_horizon_bars: FORWARD_HORIZON_BARS,
      stride: 5
    )
    
    buckets = SignatureAnalyzer.analyze(swing_events: train_events, baseline_samples: train_baselines)
    
    tradeable_buckets = {}
    buckets.each do |bucket|
      plan = DynamicRiskPlanner.plan(bucket_stats: bucket)
      next unless plan.tradeable
      
      bucket_events = train_events.select { |e| e.context[:regime_state] == bucket.bucket_key }
      dominant_direction = bucket_events.group_by(&:direction).max_by { |_, v| v.size }&.first
      next if dominant_direction.nil?
      
      tradeable_buckets[bucket.bucket_key] = { plan: plan, direction: dominant_direction }
    end
    
    tradeable_buckets_by_symbol[symbol] = tradeable_buckets
  end
  
  # Run execution for each filter
  filters.each do |part_key, cfg|
    sc = scenarios[part_key]
    
    simulator = GatedSimulator.new(
      starting_balance_inr: sc[:compounded_balance_usdt] * EXCHANGE_RATE,
      exchange_rate_inr_usdt: EXCHANGE_RATE
    )
    
    params_by_symbol = SYMBOLS.each_with_object({}) do |sym, h|
      h[sym] = { stop_atr_buffer: STOP_ATR_BUFFER, entry_delay_bars: ENTRY_DELAY_BARS, forward_horizon_bars: FORWARD_HORIZON_BARS }
    end
    
    res = simulator.run_with_filter(
      candles_by_symbol: candles_by_symbol,
      funding_series_by_symbol: funding_series_by_symbol,
      swings_by_symbol: swings_by_symbol,
      regimes_by_symbol: regimes_by_symbol,
      feature_extractor_by_symbol: feature_extractor_by_symbol,
      tradeable_buckets_by_symbol: tradeable_buckets_by_symbol,
      params_by_symbol: params_by_symbol,
      aligned_4h_by_symbol: aligned_4h_regimes_by_symbol,
      filter_proc: cfg[:filter_lambda]
    )
    
    fold_trades = res[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
    sc[:trades] += fold_trades
    sc[:compounded_balance_usdt] += fold_trades.sum(&:net_pnl_usdt)
    
    sc[:equity_curve] << {
      fold: fold_idx + 1,
      timestamp: test_end_ts,
      balance_inr: (sc[:compounded_balance_usdt] * EXCHANGE_RATE).round(2),
      trades_in_fold: fold_trades.size
    }
  end
end

# Calculate aggregate results & prepare export payload
export_payload = {}

puts "\n" + "=" * 70
puts "COMPOSITE MARKET CONTEXT COMPARATIVE LEADERBOARD"
puts "=" * 70

scenarios.each do |key, sc|
  total_trades = sc[:trades].size
  winning_trades = sc[:trades].count { |t| t.net_pnl_usdt.positive? }
  win_rate = total_trades.positive? ? (winning_trades.to_f / total_trades) : 0.0
  
  final_balance_usdt = sc[:compounded_balance_usdt]
  final_balance_inr = final_balance_usdt * EXCHANGE_RATE
  net_profit_inr = final_balance_inr - STARTING_BALANCE_INR
  net_profit_pct = (net_profit_inr / STARTING_BALANCE_INR) * 100.0
  
  # Drawdown calculation
  running_equity = STARTING_BALANCE_INR / EXCHANGE_RATE
  peak_equity = running_equity
  max_dd = 0.0
  sc[:trades].sort_by(&:entry_ts).each do |t|
    running_equity += t.net_pnl_usdt
    peak_equity = [peak_equity, running_equity].max
    dd = (peak_equity - running_equity) / peak_equity
    max_dd = [max_dd, dd].max
  end
  
  # Sharpe Ratio
  pnl_values = sc[:trades].map(&:net_pnl_usdt)
  sharpe = 0.0
  if pnl_values.size > 5
    mean = pnl_values.sum / pnl_values.size.to_f
    variance = pnl_values.sum { |v| (v - mean)**2 } / pnl_values.size.to_f
    std = Math.sqrt(variance)
    sharpe = std.zero? ? 0.0 : (mean / std) * Math.sqrt(252)
  end
  
  puts sc[:name]
  puts "  Net Profit: #{net_profit_inr.round(2)} INR (#{net_profit_pct.round(2)}%)"
  puts "  Drawdown:   #{(max_dd * 100.0).round(2)}% | Sharpe Ratio: #{sharpe.round(2)}"
  puts "  Win Rate:   #{(win_rate * 100.0).round(2)}% (#{winning_trades} wins, #{total_trades - winning_trades} losses)"
  
  # Format trades for JSON export
  trade_list = sc[:trades].sort_by(&:entry_ts).map do |t|
    {
      symbol: t.symbol,
      direction: t.direction,
      entry_time: Time.at(t.entry_ts).strftime("%m-%d %H:%M"),
      exit_time: Time.at(t.exit_ts).strftime("%m-%d %H:%M"),
      entry_price: t.entry_price.round(4),
      exit_price: t.exit_price.round(4),
      quantity: t.quantity,
      notional: t.notional,
      leverage: t.leverage,
      net_pnl_inr: t.net_pnl_inr.round(2),
      ending_equity_inr: (t.ending_equity_usdt * EXCHANGE_RATE).round(2),
      regime: t.bucket_key
    }
  end
  
  export_payload[key] = {
    name: sc[:name],
    metrics: {
      starting_balance_inr: STARTING_BALANCE_INR.round(2),
      final_balance_inr: final_balance_inr.round(2),
      net_profit_inr: net_profit_inr.round(2),
      net_profit_pct: net_profit_pct.round(2),
      max_drawdown_pct: (max_dd * 100.0).round(2),
      sharpe_ratio: sharpe.round(2),
      total_trades: total_trades,
      win_rate_pct: (win_rate * 100.0).round(2),
      wins: winning_trades,
      losses: total_trades - winning_trades
    },
    equity_curve: sc[:equity_curve],
    trades: trade_list
  }
end

# Compile HTML dashboard with inline data
template_path = File.join(root, "data", "dashboard_template.html")
if File.exist?(template_path)
  template_content = File.read(template_path)
  
  # Inject backtest data
  compiled_content = template_content.gsub(
    "// INSERT_BACKTEST_DATA_HERE",
    "window.backtestData = #{JSON.dump(export_payload)};"
  )
  
  # Replace the sidebar container
  compiled_content = compiled_content.gsub(
    /<div class="sidebar">[\s\S]*?<\/div>/,
    '<div class="sidebar" id="sidebar-container"><h2 style="font-size: 1.2rem; margin-bottom: 0.5rem; color: var(--text-secondary);">Select Context Filter</h2></div>'
  )
  
  # Inject dynamic UI initialization script
  ui_generator_js = <<~JS
    function initializeUI() {
        if (!window.backtestData) {
            console.error("backtestData is missing.");
            return;
        }
        
        const sidebarContainer = document.getElementById('sidebar-container');
        sidebarContainer.innerHTML = \'<h2 style="font-size: 1.2rem; margin-bottom: 0.5rem; color: var(--text-secondary);">Select Context Filter</h2>\';
        
        const strategyKeys = Object.keys(backtestData);
        if (strategyKeys.length > 0) {
            selectedStrategy = strategyKeys[0];
        }
        
        const colors = ['var(--color-baseline)', 'var(--color-calibrated)', 'var(--color-mtf)', '#f59e0b', '#ec4899', '#10b981'];
        
        strategyKeys.forEach((strategy, idx) => {
            const info = backtestData[strategy];
            const metrics = info.metrics;
            const profitVal = metrics.net_profit_inr;
            
            const card = document.createElement('div');
            card.className = `strategy-card \${strategy === selectedStrategy ? 'active' : ''}`;
            card.setAttribute('data-strategy', strategy);
            card.style.borderColor = colors[idx % colors.length];
            
            card.innerHTML = `
                <h3 style="font-size:0.9rem">\${info.name}</h3>
                <div class="card-profit \${profitVal > 0 ? 'positive' : 'negative'}">
                    \${profitVal > 0 ? '+' : ''}\${profitVal.toLocaleString()} INR
                </div>
                <div class="card-meta">
                    <span>WR: \${metrics.win_rate_pct}%</span>
                    <span>\${metrics.total_trades} Trades</span>
                </div>
            `;
            
            card.addEventListener('click', () => {
                document.querySelectorAll('.strategy-card').forEach(c => c.classList.remove('active'));
                card.classList.add('active');
                selectedStrategy = strategy;
                renderStrategy();
            });
            
            sidebarContainer.appendChild(card);
        });
        
        renderStrategy();
        drawChart();
    }
  JS
  
  compiled_content = compiled_content.gsub(
    /function initializeUI\(\) \{[\s\S]*?\n        \}/,
    ui_generator_js
  )
  
  # Inject dynamic chart series paths JS
  chart_js_injector = <<~JS
        function drawChart() {
            const svg = document.querySelector('svg.equity-chart');
            svg.innerHTML = ''; // clear

            const margin = { top: 20, right: 30, bottom: 30, left: 60 };
            const width = 1000;
            const height = 300;

            // Injected dynamic lines grid
            for (let i = 0; i <= 5; i++) {
                const y = margin.top + (i * (height - margin.top - margin.bottom) / 5);
                const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
                line.setAttribute('x1', margin.left);
                line.setAttribute('y1', y);
                line.setAttribute('x2', width - margin.right);
                line.setAttribute('y2', y);
                line.setAttribute('class', 'grid-line');
                svg.appendChild(line);
            }

            // Find global Y min and max across all series
            let minVal = 100000;
            let maxVal = 100000;
            
            Object.keys(backtestData).forEach(strategy => {
                backtestData[strategy].equity_curve.forEach(pt => {
                    minVal = Math.min(minVal, pt.balance_inr);
                    maxVal = Math.max(maxVal, pt.balance_inr);
                });
            });

            // Padding Y-axis
            const delta = maxVal - minVal;
            minVal = Math.max(0, minVal - delta * 0.1);
            maxVal = maxVal + delta * 0.1;

            const strategyKeys = Object.keys(backtestData);
            const xMax = strategyKeys.length > 0 ? backtestData[strategyKeys[0]].equity_curve.length : 0;

            const scaleX = (x) => margin.left + (x * (width - margin.left - margin.right) / Math.max(1, xMax));
            const scaleY = (y) => height - margin.bottom - ((y - minVal) * (height - margin.top - margin.bottom) / (maxVal - minVal));

            // Axes Labels
            const yLabelsCount = 5;
            for (let i = 0; i <= yLabelsCount; i++) {
                const val = minVal + (i * (maxVal - minVal) / yLabelsCount);
                const y = scaleY(val);
                const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
                text.setAttribute('x', margin.left - 10);
                text.setAttribute('y', y + 3);
                text.setAttribute('text-anchor', 'end');
                text.setAttribute('class', 'axis-text');
                text.textContent = `${Math.round(val / 1000)}k`;
                svg.appendChild(text);
            }

            // Draw series paths
            const colors = ['var(--color-baseline)', 'var(--color-calibrated)', 'var(--color-mtf)', '#f59e0b', '#ec4899', '#10b981'];

            strategyKeys.forEach((strategy, idx) => {
                const curve = backtestData[strategy].equity_curve;
                let d = `M ${scaleX(0)} ${scaleY(100000)}`;
                
                curve.forEach((pt, idxX) => {
                    d += ` L ${scaleX(idxX + 1)} ${scaleY(pt.balance_inr)}`;
                });

                const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
                path.setAttribute('d', d);
                path.setAttribute('class', 'series');
                path.setAttribute('stroke', colors[idx % colors.length]);
                svg.appendChild(path);
            });
        }
  JS
  
  compiled_content = compiled_content.gsub(
    /function drawChart\(\) \{[\s\S]*?\n        \}/,
    chart_js_injector
  )
  
  # Change title to reflect Composite Market Context
  compiled_content = compiled_content.gsub(
    "<h1>Crypto perp futures Alpha Search Leaderboard</h1>",
    "<h1>Composite Market Context Backtest Analytics</h1>"
  )
  compiled_content = compiled_content.gsub(
    "<p>Walk-forward out-of-sample edge discovery across multiple timeframes & parameters</p>",
    "<p>Evaluating performance of 6 different context partitioners on resampled 1H candles</p>"
  )
  
  dashboard_path = File.join(root, "data", "backtest_dashboard_composite.html")
  File.write(dashboard_path, compiled_content)
  puts "HTML Dashboard compiled to #{dashboard_path} with embedded composite research data."
else
  puts "WARNING: dashboard_template.html not found at #{template_path}"
end

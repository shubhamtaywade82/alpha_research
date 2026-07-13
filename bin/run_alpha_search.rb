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
CACHE_DIR = File.join(root, "data", "cache")

STARTING_BALANCE_INR = 100_000.0
EXCHANGE_RATE = 83.5 # INR/USDT

# Load raw data
raw_candles_15m = {}
raw_funding_15m = {}

SYMBOLS.each do |symbol|
  raw_klines = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_klines_#{INTERVAL}_#{DAYS_BACK}d.json")))
  raw_funding = JSON.parse(File.read(File.join(CACHE_DIR, "#{symbol}_funding_#{DAYS_BACK}d.json")))
  raw_candles_15m[symbol] = BinanceDataLoader.klines_to_candles(raw_klines)
  raw_funding_15m[symbol] = raw_funding
end

# We will sweep:
# Timeframes: 30m, 1h, 2h
# Stops: 0.5, 1.0, 1.5
# Delays: 1, 3
# Horizons: 10, 20
# MTF Gating: false, true
# Universes: Portfolio (all 3), SOLUSDT (single), ETHUSDT (single), XRPUSDT (single)

TIMEFRAME_CONFIGS = {
  "30m" => { factor: 2, htf_factor: 8, embargo: 10 },
  "1h"  => { factor: 4, htf_factor: 16, embargo: 5 },
  "2h"  => { factor: 8, htf_factor: 16, embargo: 3 }
}.freeze

STOPS = [0.5, 1.0, 1.5].freeze
DELAYS = [1, 3].freeze
HORIZONS = [10, 20].freeze
GATING_OPTIONS = [false, true].freeze
UNIVERSES = ["Portfolio", "SOLUSDT", "ETHUSDT", "XRPUSDT"].freeze

# Pre-resample and prepare data for all timeframes
data_by_tf = {}

TIMEFRAME_CONFIGS.each do |tf_name, cfg|
  tf_data = {
    candles: {},
    funding: {},
    regimes: {},
    aligned_htf_regimes: {},
    swings: {},
    extractors: {}
  }
  
  SYMBOLS.each do |symbol|
    candles = CandleResampler.resample_candles(raw_candles_15m[symbol], cfg[:factor])
    funding = BinanceDataLoader.align_funding_series(candles, raw_funding_15m[symbol])
    profile = SymbolProfile.for(symbol)
    regimes = RegimeClassifier.new(profile).classify(candles)
    swings = SwingPointDetector.new(min_move_atr_multiple: 1.5).detect(candles)
    extractor = ContextFeatureExtractor.new(profile)
    
    # Warm up caches
    closes = candles.map { |c| c[:close] }
    extractor.ema_cache_fast = Indicators.ema(closes, profile.ema_fast)
    extractor.ema_cache_slow = Indicators.ema(closes, profile.ema_slow)
    
    # HTF regimes
    htf_candles = CandleResampler.resample_candles(raw_candles_15m[symbol], cfg[:htf_factor])
    htf_regimes = RegimeClassifier.new(profile).classify(htf_candles)
    aligned_htf = CandleResampler.align_higher_regimes(
      lower_candles: candles,
      higher_candles: htf_candles,
      higher_regimes: htf_regimes
    )
    
    tf_data[:candles][symbol] = candles
    tf_data[:funding][symbol] = funding
    tf_data[:regimes][symbol] = regimes
    tf_data[:aligned_htf_regimes][symbol] = aligned_htf
    tf_data[:swings][symbol] = swings
    tf_data[:extractors][symbol] = extractor
  end
  
  data_by_tf[tf_name] = tf_data
end

# Build folds per timeframe
folds_by_tf = {}
TIMEFRAME_CONFIGS.each do |tf_name, cfg|
  total_bars = data_by_tf[tf_name][:candles][SYMBOLS.first].size
  folds_by_tf[tf_name] = WalkForwardValidator.build_folds(
    total_bars: total_bars,
    n_folds: WALK_FORWARD_FOLDS,
    embargo_bars: cfg[:embargo]
  )
end

# Cache for tradeable buckets to speed up search sweep
# Key: [tf_name, symbol, fold_idx, stop, delay, horizon] -> tradeable_buckets
tradeable_cache = {}

results = []

puts "Running sweep of 288 strategy combinations..."

# Main sweep loop
TIMEFRAME_CONFIGS.keys.each do |tf_name|
  tf_data = data_by_tf[tf_name]
  folds = folds_by_tf[tf_name]
  
  STOPS.each do |stop|
    DELAYS.each do |delay|
      HORIZONS.each do |horz|
        GATING_OPTIONS.each do |mtf_gating|
          UNIVERSES.each do |universe|
            
            # Setup active symbols
            active_symbols = universe == "Portfolio" ? SYMBOLS : [universe]
            
            # Run walk-forward cash backtest
            compounded_balance_usdt = STARTING_BALANCE_INR / EXCHANGE_RATE
            all_trades = []
            equity_curve = []
            
            folds.each_with_index do |fold, fold_idx|
              test_start_ts = tf_data[:candles][SYMBOLS.first][fold.test_range.first][:ts]
              test_end_ts = tf_data[:candles][SYMBOLS.first][fold.test_range.max][:ts]
              
              # Get tradeable buckets per symbol (using cache)
              tradeable_buckets_by_symbol = {}
              
              active_symbols.each do |symbol|
                cache_key = [tf_name, symbol, fold_idx, stop, delay, horz]
                
                tradeable_buckets = tradeable_cache[cache_key]
                if tradeable_buckets.nil?
                  candles = tf_data[:candles][symbol]
                  swings = tf_data[:swings][symbol]
                  regimes = tf_data[:regimes][symbol]
                  funding_series = tf_data[:funding][symbol]
                  extractor = tf_data[:extractors][symbol]
                  profile = SymbolProfile.for(symbol)
                  
                  labeler = MoveLabeler.new(r_multiple_target: profile.r_multiple_target, stop_atr_buffer: stop)
                  train_events = labeler.label_signal_events(
                    candles: candles[0..fold.train_range.end],
                    swings: swings.select { |s| fold.train_range.cover?(s.index) },
                    regimes: regimes[0..fold.train_range.end],
                    funding_series: funding_series[0..fold.train_range.end],
                    feature_extractor: extractor,
                    entry_delay_bars: delay,
                    forward_horizon_bars: horz
                  )
                  
                  train_baselines = labeler.label_baseline_samples(
                    candles: candles[0..fold.train_range.end],
                    regimes: regimes[0..fold.train_range.end],
                    funding_series: funding_series[0..fold.train_range.end],
                    feature_extractor: extractor,
                    forward_horizon_bars: horz,
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
                  
                  tradeable_cache[cache_key] = tradeable_buckets
                end
                
                tradeable_buckets_by_symbol[symbol] = tradeable_buckets
              end
              
              # Run execution on test fold
              simulator = BacktestSimulator.new(
                starting_balance_inr: compounded_balance_usdt * EXCHANGE_RATE,
                exchange_rate_inr_usdt: EXCHANGE_RATE
              )
              
              params_by_symbol = active_symbols.each_with_object({}) do |sym, h|
                h[sym] = { stop_atr_buffer: stop, entry_delay_bars: delay, forward_horizon_bars: horz }
              end
              
              htf_regimes_by_symbol = mtf_gating ? tf_data[:aligned_htf_regimes] : nil
              
              res = simulator.run(
                candles_by_symbol: tf_data[:candles].slice(*active_symbols),
                funding_series_by_symbol: tf_data[:funding].slice(*active_symbols),
                swings_by_symbol: tf_data[:swings].slice(*active_symbols),
                regimes_by_symbol: tf_data[:regimes].slice(*active_symbols),
                feature_extractor_by_symbol: tf_data[:extractors].slice(*active_symbols),
                tradeable_buckets_by_symbol: tradeable_buckets_by_symbol,
                params_by_symbol: params_by_symbol,
                htf_regimes_by_symbol: htf_regimes_by_symbol
              )
              
              fold_trades = res[:trades].select { |t| t.entry_ts >= test_start_ts && t.entry_ts <= test_end_ts }
              all_trades += fold_trades
              compounded_balance_usdt += fold_trades.sum(&:net_pnl_usdt)
              
              equity_curve << {
                fold: fold_idx + 1,
                timestamp: test_end_ts,
                balance_inr: (compounded_balance_usdt * EXCHANGE_RATE).round(2),
                trades_in_fold: fold_trades.size
              }
            end
            
            # Post-backtest metrics
            total_trades = all_trades.size
            winning_trades = all_trades.count { |t| t.net_pnl_usdt.positive? }
            win_rate = total_trades.positive? ? (winning_trades.to_f / total_trades) : 0.0
            
            final_balance_inr = compounded_balance_usdt * EXCHANGE_RATE
            net_profit_inr = final_balance_inr - STARTING_BALANCE_INR
            net_profit_pct = (net_profit_inr / STARTING_BALANCE_INR) * 100.0
            
            # Max Drawdown
            running_equity = STARTING_BALANCE_INR / EXCHANGE_RATE
            peak_equity = running_equity
            max_dd = 0.0
            all_trades.sort_by(&:entry_ts).each do |t|
              running_equity += t.net_pnl_usdt
              peak_equity = [peak_equity, running_equity].max
              dd = (peak_equity - running_equity) / peak_equity
              max_dd = [max_dd, dd].max
            end
            
            # Sharpe
            pnl_values = all_trades.map(&:net_pnl_usdt)
            sharpe = 0.0
            if pnl_values.size > 5
              mean = pnl_values.sum / pnl_values.size.to_f
              variance = pnl_values.sum { |v| (v - mean)**2 } / pnl_values.size.to_f
              std = Math.sqrt(variance)
              sharpe = std.zero? ? 0.0 : (mean / std) * Math.sqrt(252)
            end
            
            results << {
              timeframe: tf_name,
              stop: stop,
              delay: delay,
              horizon: horz,
              mtf: mtf_gating,
              universe: universe,
              net_profit_pct: net_profit_pct.round(2),
              net_profit_inr: net_profit_inr.round(2),
              max_drawdown_pct: (max_dd * 100.0).round(2),
              sharpe: sharpe.round(2),
              trades_count: total_trades,
              win_rate_pct: (win_rate * 100.0).round(2),
              trades: all_trades,
              equity_curve: equity_curve
            }
            
          end
        end
      end
    end
  end
end

# Filter out strategies with 0 trades, then rank by Net Profit %
valid_results = results.select { |r| r[:trades_count] > 3 }
ranked = valid_results.sort_by { |r| -r[:net_profit_pct] }

puts "\n======================================================================"
puts "ALPHA SEARCH LEADERBOARD (Top 10 Edge Strategies)"
puts "======================================================================"
ranked.first(10).each_with_index do |r, idx|
  puts "#{idx + 1}. [#{r[:universe]}] TF=#{r[:timeframe]} stop=#{r[:stop]} delay=#{r[:delay]} horizon=#{r[:horizon]} MTF=#{r[:mtf]}"
  puts "   Net P&L: #{r[:net_profit_pct]}% (#{r[:net_profit_inr]} INR) | Drawdown: #{r[:max_drawdown_pct]}% | Sharpe: #{r[:sharpe]} | Trades: #{r[:trades_count]} (WR: #{r[:win_rate_pct]}%)"
end

# Export top 5 strategies to backtest_results.json for the dashboard
export_payload = {}
ranked.first(5).each_with_index do |r, idx|
  key = "alpha_#{idx + 1}"
  name = "[#{r[:universe]}] TF=#{r[:timeframe]} stop=#{r[:stop]} d=#{r[:delay]} h=#{r[:horizon]} MTF=#{r[:mtf]}"
  
  # Format trades
  trade_list = r[:trades].sort_by(&:entry_ts).map do |t|
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
    name: name,
    metrics: {
      starting_balance_inr: STARTING_BALANCE_INR.round(2),
      final_balance_inr: (STARTING_BALANCE_INR + r[:net_profit_inr]).round(2),
      net_profit_inr: r[:net_profit_inr].round(2),
      net_profit_pct: r[:net_profit_pct].round(2),
      max_drawdown_pct: r[:max_drawdown_pct].round(2),
      sharpe_ratio: r[:sharpe].round(2),
      total_trades: r[:trades_count],
      win_rate_pct: r[:win_rate_pct].round(2),
      wins: r[:trades].count { |t| t.net_pnl_usdt.positive? },
      losses: r[:trades].count { |t| !t.net_pnl_usdt.positive? }
    },
    equity_curve: r[:equity_curve],
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
  
  # Replace the hardcoded sidebar card list with a dynamic card generator in JS!
  # Let's customize the HTML to render whatever keys exist in backtestData!
  compiled_content = compiled_content.gsub(
    /<div class="sidebar">[\s\S]*?<\/div>/,
    '<div class="sidebar" id="sidebar-container"><h2 style="font-size: 1.2rem; margin-bottom: 0.5rem; color: var(--text-secondary);">Select Alpha Strategy</h2><!-- Injected Dynamically --></div>'
  )
  
  # Update JavaScript UI initialization to dynamically draw sidebar cards and set active strategy
  sidebar_js_injector = <<~JS
    // Injected Dynamic Card Generator
    function initializeUI() {
        if (!window.backtestData) {
            console.error("backtestData is missing.");
            return;
        }
        
        const sidebarContainer = document.getElementById('sidebar-container');
        sidebarContainer.innerHTML = \'<h2 style="font-size: 1.2rem; margin-bottom: 0.5rem; color: var(--text-secondary);">Select Alpha Strategy</h2>\';
        
        const strategyKeys = Object.keys(backtestData);
        if (strategyKeys.length > 0) {
            selectedStrategy = strategyKeys[0];
        }
        
        strategyKeys.forEach((strategy, idx) => {
            const info = backtestData[strategy];
            const metrics = info.metrics;
            const profitVal = metrics.net_profit_inr;
            
            const card = document.createElement('div');
            card.className = `strategy-card ${strategy === selectedStrategy ? 'active' : ''}`;
            card.setAttribute('data-strategy', strategy);
            card.style.borderColor = idx === 0 ? 'var(--color-mtf)' : (idx === 1 ? 'var(--color-calibrated)' : 'var(--border-color)');
            
            card.innerHTML = `
                <h3 style="font-size:0.9rem">${info.name}</h3>
                <div class="card-profit ${profitVal > 0 ? 'positive' : 'negative'}">
                    ${profitVal > 0 ? '+' : ''}${profitVal.toLocaleString()} INR
                </div>
                <div class="card-meta">
                    <span>WR: ${metrics.win_rate_pct}%</span>
                    <span>${metrics.total_trades} Trades</span>
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
    sidebar_js_injector
  )
  
  # Update Chart Drawing JS to support dynamic keys in backtestData
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
            const colors = ['var(--color-mtf)', 'var(--color-calibrated)', '#f59e0b', '#3b82f6', '#ec4899'];

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
  
  # Change title to reflect Alpha Sweep Leaderboard
  compiled_content = compiled_content.gsub(
    "<h1>Crypto perp futures backtest analytics</h1>",
    "<h1>Crypto perp futures Alpha Search Leaderboard</h1>"
  )
  compiled_content = compiled_content.gsub(
    "<p>Walk-forward calibration & multi-timeframe strategy evaluation</p>",
    "<p>Walk-forward out-of-sample edge discovery across multiple timeframes & parameters</p>"
  )
  
  dashboard_path = File.join(root, "data", "backtest_dashboard.html")
  File.write(dashboard_path, compiled_content)
  puts "HTML Dashboard compiled to #{dashboard_path} with embedded Alpha Search Leaderboard."
else
  puts "WARNING: dashboard_template.html not found at #{template_path}"
end

# frozen_string_literal: true

require "json"
require "time"

class ExperimentStore
  def initialize(path)
    @path = path
    @experiments = []
    load if File.exist?(@path)
  end

  def record(entry)
    entry[:id] = @experiments.size + 1
    entry[:timestamp] = Time.now.utc.iso8601
    @experiments << entry
    File.open(@path, "a") { |f| f.puts(JSON.generate(deep_plain(entry))) }
    entry[:id]
  end

  def all
    @experiments
  end

  def query(filters = {})
    @experiments.select do |exp|
      filters.all? { |k, v| exp[k] == v || exp[k.to_s] == v }
    end
  end

  def count
    @experiments.size
  end

  def leaderboard(filters: {}, metric:, ascending: false, top_n: 20)
    filtered = query(filters)
    filtered.select { |e| e.dig("walk_forward", "aggregate") || e.dig(:walk_forward, :aggregate) }
            .sort_by { |e| -(e.dig("walk_forward", "aggregate", metric) || e.dig(:walk_forward, :aggregate, metric) || -999) }
            .first(top_n)
  end

  def trending_bear_leaderboard(top_n: 20)
    # Walk-forward filtered to configurations where trending bear has edge
    all_has_edge = @experiments.select do |e|
      wf = e["walk_forward"] || e[:walk_forward]
      wf && wf["aggregate"] && wf["aggregate"]["mean_expectancy_r"]
    end
    all_has_edge.sort_by { |e| -(e["walk_forward"]["aggregate"]["mean_expectancy_r"] rescue -999) }
                .first(top_n)
  end

  private

  # Structs (BucketAggregate/FoldSummary/Fold) and Ranges have no #to_json
  # in stdlib, so JSON.generate silently falls back to Struct#to_s /
  # Range#to_s — recurse and convert to plain Hash/Array/String first.
  def deep_plain(obj)
    case obj
    when Struct
      deep_plain(obj.to_h)
    when Hash
      obj.transform_values { |v| deep_plain(v) }
    when Array
      obj.map { |v| deep_plain(v) }
    when Range
      obj.to_s
    else
      obj
    end
  end

  def load
    File.readlines(@path).each do |line|
      line = line.strip
      next if line.empty?
      @experiments << JSON.parse(line)
    end
  end
end

#!/usr/bin/env ruby
# frozen_string_literal: true

# Замер скорости поиска до/после оптимизации.
#
#   bundle exec rails runner scripts/benchmark_search_suggest.rb
#   QUERIES=диван,нераскладные RUNS=5 bundle exec rails runner scripts/benchmark_search_suggest.rb

require "benchmark"

queries = ENV.fetch("QUERIES", "диван,нераскладные,стол").split(",").map(&:strip).reject(&:blank?)
runs = ENV.fetch("RUNS", "3").to_i
warmup = ENV.fetch("WARMUP", "1").to_i

controller = Api::V1::SearchController.new

def measure(label, runs:, warmup:)
  warmup.times { yield }
  times = runs.times.map { Benchmark.realtime { yield } }
  avg_ms = (times.sum / times.size) * 1000
  puts format("%-42s %8.1f ms (avg of %d)", label, avg_ms, runs)
  avg_ms
end

puts "Search suggest benchmark (runs=#{runs}, warmup=#{warmup})"
puts "-" * 60

queries.each do |query|
  puts "\nQuery: #{query.inspect}"

  measure("Product.search_scope", runs: runs, warmup: warmup) do
    term = "%#{query}%"
    Product.with_available_stock.where(
      "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term",
      term: term
    ).limit(20).load
  end

  scope = Product.with_available_stock.where(
    "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term",
    term: "%#{query}%"
  )

  measure("Search::SuggestCategoryResolver", runs: runs, warmup: warmup) do
    Search::SuggestCategoryResolver.new(query, products_scope: scope).call
  end

  measure("Full suggest action (categories part)", runs: runs, warmup: warmup) do
    products = scope.includes(:category, :categories).limit(20).to_a
    Search::SuggestCategoryResolver.new(query, products: products, products_scope: scope).call
  end
end

puts "\nDone."

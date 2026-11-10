# frozen_string_literal: true

require "spec_helper"

RSpec.describe "public/robots.txt" do
  def robots_text
    File.read(File.expand_path("../../public/robots.txt", __dir__))
  end

  def rule_matches?(pattern, path)
    anchored = pattern.end_with?("$")
    body = anchored ? pattern.chop : pattern
    source = body.split("*", -1).map { |part| Regexp.escape(part) }.join(".*")
    regexp = anchored ? /\A#{source}\z/ : /\A#{source}/
    path.match?(regexp)
  end

  # Google: среди подходящих правил побеждает самое длинное, при равной длине — Allow.
  def google_allowed?(path)
    rules = robots_text.each_line.filter_map do |line|
      case line.strip
      when /\AAllow:\s*(\S+)/i then [:allow, Regexp.last_match(1)]
      when /\ADisallow:\s*(\S+)/i then [:disallow, Regexp.last_match(1)]
      end
    end

    matching = rules.select { |_type, pattern| rule_matches?(pattern, path) }
    return true if matching.empty?

    longest = matching.map { |_type, pattern| pattern.length }.max
    matching.select { |_type, pattern| pattern.length == longest }.any? { |type, _pattern| type == :allow }
  end

  it "lets crawlers open every internal search url" do
    [
      "/search",
      "/search/",
      "/search?q=stol",
      "/search/?q=stol",
      "/search/?q=kovry&page=2",
      "/search/?q=stol&sort=cheapest",
      "/search/?q=stol&min_price=10&max_price=500",
      "/search/?q=stol&filters[color][]=red&page=3",
      "/search?q=stol&sort=expensive&page=2"
    ].each do |path|
      expect(google_allowed?(path)).to be(true), "expected #{path} to be allowed"
    end
  end

  it "still blocks parameterized catalog and private areas" do
    expect(google_allowed?("/catalog/tekstil-i-kovry/?page=2")).to be(true)
    expect(google_allowed?("/catalog/tekstil-i-kovry/?sort=cheapest")).to be(false)
    expect(google_allowed?("/catalog/tekstil-i-kovry/?min_price=10")).to be(false)
    expect(google_allowed?("/admin/")).to be(false)
    expect(google_allowed?("/api/v1/products")).to be(false)
    expect(google_allowed?("/cart/")).to be(false)
  end
end

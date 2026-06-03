# frozen_string_literal: true

module Search
  # Варианты поисковой строки (мн. число → ед.) для ILIKE по товарам и категориям.
  class QueryTerms
    MIN_STEM_LENGTH = 4

    def self.for(query)
      new(query).all
    end

    def initialize(query)
      @query = query.to_s.strip
    end

    def all
      return [] if @query.blank?

      terms = [@query]
      stem = russian_plural_stem(@query)
      terms << stem if stem.present? && !stem.casecmp?(@query)
      terms.concat(Search::Synonyms.for(@query))
      terms.map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    private

    def russian_plural_stem(word)
      chars = word.mb_chars
      lower = chars.downcase.to_s
      return nil if lower.length < MIN_STEM_LENGTH

      # шкафы → шкаф, столы → стол
      return chars[0...-1].to_s if lower.end_with?("ы")

      nil
    end
  end
end

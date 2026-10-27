# frozen_string_literal: true

module Search
  # Варианты поисковой строки (мн. число → ед.) для ILIKE по товарам и категориям.
  class QueryTerms
    MIN_STEM_LENGTH = 4
    # 296.220.94 — один артикул IKEA (XXX.XXX.XX), а не три отдельных числа.
    ARTICLE_NUMBER = /\A\s*s?\d{3}\s*[.\-]\s*\d{3}\s*[.\-]\s*\d{2}\s*\z/i
    ARTICLE_NUMBER_TOKEN = /s?\d{3}[.\-]\d{3}[.\-]\d{2}/i

    def self.for(query)
      new(query).all
    end

    def self.groups_for(query)
      new(query).groups
    end

    def self.article_number?(query)
      query.to_s.match?(ARTICLE_NUMBER)
    end

    def self.normalized_article_number(query)
      query.to_s.gsub(/\D/, "")
    end

    def initialize(query)
      @query = query.to_s.strip
    end

    def all
      return [] if @query.blank?

      (phrase_terms + groups.flatten).uniq
    end

    def groups
      return [] if @query.blank?

      extracted_tokens = tokens
      return [phrase_terms] if extracted_tokens.blank?

      extracted_tokens.map do |token|
        token_terms(token)
      end
    end

    private

    def phrase_terms
      terms = [@query]
      stem = russian_plural_stem(@query)
      terms << stem if stem.present? && !stem.casecmp?(@query)
      terms.concat(Search::Synonyms.for(@query))
      normalize_terms(terms)
    end

    def token_terms(token)
      terms = [token]
      stem = russian_plural_stem(token)
      terms << stem if stem.present? && !stem.casecmp?(token)
      terms.concat(Search::Synonyms.for(token))
      normalize_terms(terms)
    end

    def tokens
      if self.class.article_number?(@query)
        return [self.class.normalized_article_number(@query)]
      end

      @query.downcase.scan(/#{ARTICLE_NUMBER_TOKEN}|[[:alnum:]а-яё]+/i).map { |token|
        token.match?(ARTICLE_NUMBER_TOKEN) ? token.gsub(/\D/, "") : token
      }.uniq
    end

    def normalize_terms(values)
      values.map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

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

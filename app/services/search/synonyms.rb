# frozen_string_literal: true

module Search
  # Ручной словарь пользовательских запросов для поиска и autocomplete.
  # Нужен для IKEA-терминов, где пользователь ищет бытовое слово,
  # а в карточках/категориях используется другое название: «шкаф» → «гардероб», «PAX».
  class Synonyms
    GROUPS = [
      %w[шкаф шкафы гардероб гардеробы pax пакс платяной хранение],
      %w[диван диваны sofa софа раскладной угловой],
      %w[кровать кровати bed каркас матрас],
      %w[стол столы table письменный обеденный],
      %w[стул стулья chair кресло кресла],
      %w[комод комоды хранение],
      %w[полка полки стеллаж стеллажи shelving],
      %w[кухня кухни кухонный metod метод],
      %w[лампа лампы светильник светильники освещение]
    ].freeze

    INDEX = GROUPS.each_with_object({}) do |group, index|
      group.each { |term| index[term] = group }
    end.freeze

    def self.for(query)
      new(query).all
    end

    def initialize(query)
      @query = query.to_s.strip
    end

    def all
      tokens.flat_map { |token| INDEX[token] || [] }
            .map(&:to_s)
            .map(&:strip)
            .reject(&:blank?)
            .uniq
    end

    private

    def tokens
      @query.downcase.scan(/[[:alnum:]а-яё]+/i).flat_map do |token|
        variants = [token]
        stem = russian_plural_stem(token)
        variants << stem if stem.present?
        variants
      end.uniq
    end

    def russian_plural_stem(word)
      return nil if word.length < QueryTerms::MIN_STEM_LENGTH

      word.end_with?("ы") ? word[0...-1] : nil
    end
  end
end

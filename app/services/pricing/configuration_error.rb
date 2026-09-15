# frozen_string_literal: true

module Pricing
  class ConfigurationError < StandardError
    attr_reader :key

    def initialize(message = nil, key: nil)
      @key = key
      super(message || "Некорректная конфигурация ценообразования#{key ? " (#{key})" : ""}")
    end
  end
end

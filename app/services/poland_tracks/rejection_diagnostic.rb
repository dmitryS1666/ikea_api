# frozen_string_literal: true

require "json"

module PolandTracks
  # Only known field names and normalized codes leave this parser.
  # Never persist upstream messages, input values or arbitrary JSON keys.
  class RejectionDiagnostic
    ROOT_FIELDS = %w[nomerikea delivery_type weight europost_track delivery_address pvz recipient items].freeze
    RECIPIENT_FIELDS = %w[first_name middle_name last_name email phone phone_country birthdate
                          document_country address_country passport_serial passport_number iin
                          passport_date passport_founder region city street building corpus apartment index].freeze
    ITEM_FIELDS = %w[name count price link].freeze
    MAX_BYTES = 65_536
    MAX_FIELDS = 20

    def self.summary(body)
      return "validation=body_too_large" if body.to_s.bytesize > MAX_BYTES
      data = JSON.parse(body.to_s)
      rows = []
      if data.is_a?(Hash)
        errors = data["errors"] || data["detail"] || data
        if errors.is_a?(Hash)
          errors.first(MAX_FIELDS).each do |field, value|
            if field == "recipient" && value.is_a?(Hash)
              value.first(MAX_FIELDS).each { |key, error| rows << ["recipient.#{key}", error] }
            else
              rows << [field, value]
            end
          end
        elsif errors.is_a?(Array)
          errors.first(MAX_FIELDS).each do |error|
            next unless error.is_a?(Hash)
            location = error["loc"]
            if location.is_a?(Array)
              location = location.drop(1) if location.first == "body"
              rows << [location.join("."), error["type"]]
            elsif error["field"].is_a?(String)
              rows << [error["field"], error["code"]]
            end
          end
        end
      end
      entries = rows.first(MAX_FIELDS).filter_map do |field, error|
        next unless allowed_field?(field)
        "#{field}(#{code(error)})"
      end.uniq
      entries.any? ? "fields=#{entries.join(',')}" : "validation=unrecognized_response"
    rescue JSON::ParserError, EncodingError
      "validation=unreadable_response"
    end

    def self.allowed_field?(field)
      return false unless field.is_a?(String)
      return true if ROOT_FIELDS.include?(field)
      return true if RECIPIENT_FIELDS.any? { |key| field == "recipient.#{key}" }
      match = field.match(/\Aitems\.(?:\d{1,4}|\*)\.([a-z_]+)\z/)
      match && ITEM_FIELDS.include?(match[1])
    end

    def self.code(error)
      error = error.first if error.is_a?(Array)
      error = error["code"] if error.is_a?(Hash)
      case error
      when "required", "missing", "value_error.missing", "blank", "can't be blank",
           /\AThe [a-zA-Z0-9_.* ]+ field is required\.\z/
        "required"
      when "unique", "taken", "already_exists", "has already been taken",
           /\AThe [a-zA-Z0-9_.* ]+ has already been taken\.\z/
        "already_exists"
      when "invalid", "invalid_format", "value_error", "email", "url", "is invalid",
           /\AThe selected [a-zA-Z0-9_.* ]+ is invalid\.\z/
        "invalid_format"
      when "min", "max", "greater_than_equal", "less_than_equal"
        "out_of_range"
      else
        # Free text may contain personal data: do not retain even a fragment.
        "details_redacted"
      end
    end
    private_class_method :allowed_field?, :code
  end
end

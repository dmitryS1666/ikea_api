# frozen_string_literal: true

module ApiValidationErrors
  extend ActiveSupport::Concern

  private

  def render_validation_errors(record, summary: nil)
    field_errors = record.errors.map do |error|
      { field: error.attribute.to_s, message: error.message }
    end
    messages = field_errors.pluck(:message)

    render json: {
      error: summary.presence || messages.join(" "),
      errors: messages,
      field_errors: field_errors
    }, status: :unprocessable_entity
  end
end

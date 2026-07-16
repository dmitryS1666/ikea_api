# frozen_string_literal: true

require "csv"

module Admin
  class MarketingEmailsExport
    HEADERS = [
      "Email",
      "ID пользователя",
      "Имя",
      "Фамилия"
    ].freeze

    def self.call(scope = User.marketing_email_recipients)
      csv = CSV.generate(col_sep: ";", force_quotes: true) do |output|
        output << HEADERS
        scope.order(id: :asc).find_each do |user|
          output << [
            user.email,
            user.id,
            user.first_name,
            user.last_name
          ]
        end
      end

      "\uFEFF#{csv}"
    end
  end
end

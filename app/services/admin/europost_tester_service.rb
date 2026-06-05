# frozen_string_literal: true

module Admin
  # Helper/service for manual Europost REST API checks from Trestle admin.
  # It intentionally does not persist orders: it calls the same low-level
  # EuropostApiService methods used by production services and shows payload/raw response.
  class EuropostTesterService
    Result = Struct.new(:success?, :status, :payload, :raw_response, :track_number, :amount, :currency, :error, keyword_init: true)

    STORE_TYPE_OPTIONS = [
      ["ОПС / пункт выдачи", "1"],
      ["Склад", "3"],
      ["ОПС при складе", "4"]
    ].freeze

    DELIVERY_KIND_OPTIONS = [
      ["ОПС → ОПС / ПВЗ", "pickup"],
      ["ОПС → дверь / курьер", "courier"]
    ].freeze

    class << self
      def env_status
        {
          rest_api_base_url: EuropostApiService.rest_api_base_url,
          api_token_present: ENV["EUROPOST_API_TOKEN"].to_s.strip.present?,
          store_id_start: ENV["EUROPOST_STORE_ID_START"].to_s.strip.presence,
          store_id_finish: ENV["EUROPOST_STORE_ID_FINISH"].to_s.strip.presence,
          contractor_unn: ENV["EUROPOST_CONTRACTOR_UNN"].to_s.strip.presence,
          delivery_type: ENV["EUROPOST_DELIVERY_TYPE"].to_s.strip.presence || "1",
          courier_delivery_type: ENV["EUROPOST_COURIER_DELIVERY_TYPE"].to_s.strip.presence || "2"
        }
      end

      def default_params
        {
          "store_type" => "1",
          "delivery_kind" => "pickup",
          "store_id_start" => ENV["EUROPOST_STORE_ID_START"].to_s.strip,
          "store_id_finish" => ENV["EUROPOST_STORE_ID_FINISH"].to_s.strip,
          "weight" => "1.0",
          "length" => "30",
          "width" => "20",
          "height" => "10",
          "declared_amount" => "50.00",
          "shipment_payer" => ENV.fetch("EUROPOST_SHIPMENT_PAYER", "0"),
          "packing_payer" => ENV.fetch("EUROPOST_PACKING_PAYER", "0"),
          "cash_on_delivery_payer" => ENV.fetch("EUROPOST_CASH_ON_DELIVERY_PAYER", "1"),
          "contractor_unn" => ENV["EUROPOST_CONTRACTOR_UNN"].to_s.strip,
          "receiver_phone_number" => "375291234567",
          "receiver_email" => "test@example.com",
          "receiver_name" => "Тест",
          "receiver_surname" => "Европочта",
          "receiver_patronymic_name" => "Икеевич",
          "external_id" => "IKEYA-TEST-#{Time.current.strftime('%Y%m%d%H%M%S')}",
          "address_city" => "Минск",
          "address_street" => "Ленина",
          "address_house_number" => "1",
          "flat_number" => "1"
        }
      end

      def load_stores(type:)
        rows = EuropostApiService.external_stores(type: type)
        Array(rows).filter_map { |row| normalize_store_row(row) }.sort_by { |row| [row[:city].to_s, row[:name].to_s, row[:id].to_s] }
      end

      def calculate(params)
        payload = build_payment_payload(params)
        error = validate_payment_payload(payload, params)
        return failure(:validation_error, payload: payload, error: error) if error.present?

        raw = EuropostApiService.postal_payment_calculate(data: payload)
        parsed = extract_amount_and_currency(raw)
        Result.new(
          success?: true,
          status: :calculated,
          payload: payload,
          raw_response: raw,
          amount: parsed[:amount],
          currency: parsed[:currency]
        )
      rescue EuropostApiService::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
        failure(:api_error, payload: defined?(payload) ? payload : nil, error: "#{e.class}: #{e.message}")
      rescue StandardError => e
        failure(:error, payload: defined?(payload) ? payload : nil, error: "#{e.class}: #{e.message}")
      end

      def create_shipment(params)
        payload = build_create_payload(params)
        error = validate_create_payload(payload, params)
        return failure(:validation_error, payload: payload, error: error) if error.present?

        unless truthy?(params[:confirm_create] || params["confirm_create"])
          return failure(
            :confirmation_required,
            payload: payload,
            error: "Для реального POST /api/external/postal/create отметьте чекбокс подтверждения создания тестовой ПчО."
          )
        end

        raw = EuropostApiService.postal_create(data: payload)
        track_number = extract_track_number(raw)
        Result.new(
          success?: track_number.present?,
          status: track_number.present? ? :created : :track_number_missing,
          payload: payload,
          raw_response: raw,
          track_number: track_number,
          error: track_number.present? ? nil : "Европочта ответила успешно, но номер ПчО не найден в ответе."
        )
      rescue EuropostApiService::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
        failure(:api_error, payload: defined?(payload) ? payload : nil, error: "#{e.class}: #{e.message}")
      rescue StandardError => e
        failure(:error, payload: defined?(payload) ? payload : nil, error: "#{e.class}: #{e.message}")
      end

      def build_payment_payload(params)
        kind = delivery_kind(params)
        payload = {
          "is_juristic" => boolean_value(params[:is_juristic] || params["is_juristic"], default: true),
          "delivery_type" => europost_delivery_type(kind),
          "store_id_start" => integer_value(params[:store_id_start] || params["store_id_start"]),
          "weight" => decimal_value(params[:weight] || params["weight"]),
          "shipment_payer" => integer_value(params[:shipment_payer] || params["shipment_payer"], default: 0),
          "cash_on_delivery_payer" => integer_value(params[:cash_on_delivery_payer] || params["cash_on_delivery_payer"], default: 1)
        }

        copy_optional_decimal!(payload, "declared_amount", params)
        copy_optional_decimal!(payload, "payment_amount", params)
        copy_optional_boolean!(payload, "is_completeness_check", params)
        copy_optional_boolean!(payload, "is_fragile", params)
        copy_optional_boolean!(payload, "is_inventory", params)
        copy_optional_boolean!(payload, "is_oversize", params)
        copy_optional_boolean!(payload, "is_relabeling", params)

        if kind == "pickup"
          payload["store_id_finish"] = integer_value(params[:store_id_finish] || params["store_id_finish"])
        else
          address_id = integer_value(params[:address_id] || params["address_id"])
          payload["address_id"] = address_id if address_id.present?
        end

        payload.compact
      end

      def build_create_payload(params)
        kind = delivery_kind(params)
        payload = build_payment_payload(params).merge(
          "is_auto_delivery" => boolean_value(params[:is_auto_delivery] || params["is_auto_delivery"], default: false),
          "receiver_phone_number" => normalized_phone(params[:receiver_phone_number] || params["receiver_phone_number"]),
          "receiver_email" => string_value(params[:receiver_email] || params["receiver_email"]),
          "receiver_name" => string_value(params[:receiver_name] || params["receiver_name"]),
          "receiver_surname" => string_value(params[:receiver_surname] || params["receiver_surname"]),
          "receiver_patronymic_name" => string_value(params[:receiver_patronymic_name] || params["receiver_patronymic_name"]),
          "info_sender" => string_value(params[:info_sender] || params["info_sender"]) || "IKEYA admin Europost test",
          "external_id" => string_value(params[:external_id] || params["external_id"]) || "IKEYA-TEST-#{Time.current.strftime('%Y%m%d%H%M%S')}",
          "height" => decimal_value(params[:height] || params["height"]),
          "width" => decimal_value(params[:width] || params["width"]),
          "length" => decimal_value(params[:length] || params["length"]),
          "packing_payer" => integer_value(params[:packing_payer] || params["packing_payer"], default: 0),
          "contractor_unn" => integer_value(params[:contractor_unn] || params["contractor_unn"])
        ).compact

        if kind == "courier"
          payload["address_city"] = string_value(params[:address_city] || params["address_city"])
          payload["address_street"] = string_value(params[:address_street] || params["address_street"])
          payload["address_house_number"] = string_value(params[:address_house_number] || params["address_house_number"])
          payload["flat_number"] = string_value(params[:flat_number] || params["flat_number"])
          payload["address_full"] = string_value(params[:address_full] || params["address_full"]) || build_address_full(payload)
        end

        payload.compact
      end

      private

      def normalize_store_row(row)
        return nil unless row.is_a?(Hash)

        id = row["id"] || row[:id] || row["store_id"] || row[:store_id]
        return nil if id.blank?

        city = row["city"] || row[:city] || row.dig("address", "city") || row.dig(:address, :city)
        address = row["address"] || row[:address] || row["address_full"] || row[:address_full]
        name = row["name"] || row[:name] || row["title"] || row[:title] || row["object_name"] || row[:object_name]

        {
          id: id.to_s,
          name: name.to_s.strip.presence || "ОПС #{id}",
          city: city.to_s.strip.presence,
          address: address.is_a?(Hash) ? address.compact.map { |k, v| "#{k}: #{v}" }.join(", ") : address.to_s.strip.presence,
          raw: row
        }
      end

      def delivery_kind(params)
        value = (params[:delivery_kind] || params["delivery_kind"]).to_s.strip
        value == "courier" ? "courier" : "pickup"
      end

      def europost_delivery_type(kind)
        if kind == "courier"
          integer_value(ENV["EUROPOST_COURIER_DELIVERY_TYPE"], default: 2)
        else
          integer_value(ENV["EUROPOST_DELIVERY_TYPE"], default: 1)
        end
      end

      def validate_payment_payload(payload, params)
        missing = []
        missing << "store_id_start" if payload["store_id_start"].blank?
        missing << "weight" unless payload["weight"].to_f.positive?
        missing << "store_id_finish" if delivery_kind(params) == "pickup" && payload["store_id_finish"].blank?
        missing.any? ? "Заполните обязательные поля: #{missing.join(', ')}" : nil
      end

      def validate_create_payload(payload, params)
        missing = []
        missing << "store_id_start" if payload["store_id_start"].blank?
        missing << "store_id_finish" if delivery_kind(params) == "pickup" && payload["store_id_finish"].blank?
        missing << "weight" unless payload["weight"].to_f.positive?
        missing << "receiver_phone_number" if payload["receiver_phone_number"].blank?
        missing << "receiver_name" if payload["receiver_name"].blank?
        missing << "receiver_surname" if payload["receiver_surname"].blank?
        missing << "contractor_unn" if payload["contractor_unn"].blank?
        missing << "length/width/height" unless %w[length width height].all? { |key| payload[key].to_f.positive? }

        if delivery_kind(params) == "courier"
          missing << "address_city" if payload["address_city"].blank?
          missing << "address_street" if payload["address_street"].blank?
          missing << "address_house_number" if payload["address_house_number"].blank?
        end

        missing.any? ? "Заполните обязательные поля: #{missing.join(', ')}" : nil
      end

      def extract_amount_and_currency(raw)
        return { amount: nil, currency: nil } unless raw.is_a?(Hash)

        sender_pays = decimal_value(raw["sender_pays"] || raw[:sender_pays])
        receiver_pays = decimal_value(raw["receiver_pays"] || raw[:receiver_pays])
        if sender_pays || receiver_pays
          return { amount: sender_pays.to_f + receiver_pays.to_f, currency: raw["currency"] || raw[:currency] || "BYN" }
        end

        %w[shipment_price total amount price cost sum].each do |key|
          amount = decimal_value(raw[key] || raw[key.to_sym])
          return { amount: amount, currency: raw["currency"] || raw[:currency] || "BYN" } if amount&.positive?
        end

        data = raw["data"] || raw[:data]
        return extract_amount_and_currency(data) if data.is_a?(Hash)

        { amount: nil, currency: raw["currency"] || raw[:currency] }
      end

      def extract_track_number(raw)
        return nil unless raw.is_a?(Hash)

        direct = raw["number"] || raw[:number] || raw["track_number"] || raw[:track_number] || raw["postal_number"] || raw[:postal_number]
        return direct.to_s.strip.presence if direct.present?

        data = raw["data"] || raw[:data]
        return extract_track_number(data) if data.is_a?(Hash)

        nil
      end

      def failure(status, payload:, error:)
        Result.new(success?: false, status: status, payload: payload, error: error)
      end

      def integer_value(value, default: nil)
        string = value.to_s.strip
        return default if string.blank?

        Integer(string)
      rescue ArgumentError, TypeError
        default
      end

      def decimal_value(value)
        string = value.to_s.tr(",", ".").strip
        return nil if string.blank?

        Float(string)
      rescue ArgumentError, TypeError
        nil
      end

      def boolean_value(value, default: nil)
        string = value.to_s.strip.downcase
        return default if string.blank?
        return true if %w[1 true yes y да on].include?(string)
        return false if %w[0 false no n нет off].include?(string)

        default
      end

      def truthy?(value)
        boolean_value(value, default: false) == true
      end

      def string_value(value)
        value.to_s.strip.presence
      end

      def normalized_phone(value)
        value.to_s.gsub(/\D+/, "").presence
      end

      def copy_optional_decimal!(payload, key, params)
        value = decimal_value(params[key] || params[key.to_sym])
        payload[key] = value if value.present?
      end

      def copy_optional_boolean!(payload, key, params)
        return unless params.key?(key) || params.key?(key.to_sym)

        payload[key] = boolean_value(params[key] || params[key.to_sym], default: false)
      end

      def build_address_full(payload)
        [
          payload["address_city"],
          payload["address_street"],
          payload["address_house_number"].present? ? "д. #{payload['address_house_number']}" : nil,
          payload["flat_number"].present? ? "кв. #{payload['flat_number']}" : nil
        ].compact_blank.join(", ").presence
      end
    end
  end
end

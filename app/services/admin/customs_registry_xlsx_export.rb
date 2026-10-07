# frozen_string_literal: true

require "axlsx"

module Admin
  # XLSX «Реестр» для таможенного брокера (формат Ikea.xlsx).
  # Недостающие поля заполняются как «Н/Д» или оставляются пустыми по шаблону.
  class CustomsRegistryXlsxExport
    NA = "Н/Д"
    SHEET_NAME = "Реестр"
    BRAND = "ikea"
    SIZE = "o/s"
    CURRENCY = "PLN"
    COD_CURRENCY = "RUB"
    SHOP = "ikeya.by"

    PERSONAL_DATA_TEXT =
      "Выражаю свое согласие на сбор, обработку и предоставление в таможенные органы моих персональных данных"
    CUSTOMS_BROKER_TEXT =
      "Принимаю условия публичного договора-оферты на оказание услуг Таможенного представителя " \
      "№ТА-0600/0000173 от 01.04.2023 "

    HEADERS = [
      "Номер отправления ИМ",
      "Номер заказа",
      "Номер ШК места",
      "Номер места",
      "ФИО получателя",
      "Email",
      "Телефон получателя",
      "Серия паспорта получателя",
      "Номер паспорта получателя",
      "Дата выдачи получателя",
      "Орган выдачи получателя",
      "Идентификационный налоговый номер получателя",
      "Дата рождения получателя",
      "Индекс получателя",
      "Страна получателя",
      "Область получателя",
      "Город получателя",
      "Адрес получателя",
      "Код ПВЗ",
      "Комментарий",
      "Ссылка на товар ikeya.by",
      "Код ТН ВЭД",
      "Наименование ТН ВЭД",
      "Код товара(Артикул)",
      "Наименование товара",
      "Бренд товара",
      "Размер товара",
      "Количество единиц товара",
      "Объявленная стоимость за ед . товара",
      "Объявленная стоимость позиции",
      "Общая стоимость посылки",
      "Валюта объявленной стоимости",
      "Вес позиции",
      "Вес нетто за единицу товара",
      "Общий вес с ТУ",
      "Инвойс",
      "Дата заказа",
      "Наложенный платеж",
      "Валюта наложенного платежа",
      "Продавец",
      "Адрес продавца",
      "Отправитель",
      "Адрес отправителя",
      "Магазин",
      "Адрес прописки (Область)",
      "Адрес прописки - Город",
      "Адрес прописки - Улица",
      "Адрес прописки - Дом",
      "Адрес прописки - Корпус",
      "Адрес прописки - Квартира",
      "Адрес прописки - Индекс",
      "Дата согласия 1",
      "Дата согласия 2",
      "Персональные данные",
      "Договор с таможенным брокером"
    ].freeze

    # Оплаченные и дальше по логистическому пайплайну (без черновиков/отмен).
    EXPORTABLE_STATUSES = %w[
      paid purchased received_poland preparing_for_shipment export_eu
      customs_poland on_border customs_belarus shipped arrived_pvz
      handed_to_courier handed_to_courier_ikeya completed
    ].freeze

    Result = Struct.new(:xlsx, :orders_count, :rows_count, :from_date, :to_date, keyword_init: true)

    def self.call(from_date:, to_date:)
      new(from_date: from_date, to_date: to_date).call
    end

    def self.orders_scope(from_date:, to_date:)
      range = date_range(from_date, to_date)
      Order.where(checkout_draft: false, status: EXPORTABLE_STATUSES, created_at: range)
           .includes(:user, :poland_track_export, :consent_records, order_items: :product)
           .order(created_at: :asc, id: :asc)
    end

    def self.count_orders(from_date:, to_date:)
      orders_scope(from_date: from_date, to_date: to_date).count
    end

    def self.date_range(from_date, to_date)
      from = parse_date!(from_date, :from)
      to = parse_date!(to_date, :to)
      raise ArgumentError, "Дата «по» не может быть раньше даты «с»" if to < from

      from.beginning_of_day..to.end_of_day
    end

    def self.parse_date!(value, label)
      raise ArgumentError, "Укажите дату «#{label == :from ? 'с' : 'по'}»" if value.blank?

      case value
      when Date then value
      when Time, ActiveSupport::TimeWithZone then value.to_date
      else Date.parse(value.to_s)
      end
    rescue Date::Error, ArgumentError
      raise ArgumentError, "Некорректная дата «#{label == :from ? 'с' : 'по'}»"
    end

    def initialize(from_date:, to_date:)
      @from_date = self.class.parse_date!(from_date, :from)
      @to_date = self.class.parse_date!(to_date, :to)
      raise ArgumentError, "Дата «по» не может быть раньше даты «с»" if @to_date < @from_date
    end

    def call
      orders = self.class.orders_scope(from_date: @from_date, to_date: @to_date)
      package_seq = 0
      rows = []

      orders.find_each do |order|
        items = order.order_items.sort_by(&:id)
        next if items.empty?

        package_seq += 1
        package_total_pln = package_total_pln(items)
        package_weight = package_weight_kg(order)
        ctx = order_context(order, package_seq)

        items.each_with_index do |item, index|
          rows << build_row(
            order: order,
            item: item,
            line_no: index + 1,
            ctx: ctx,
            package_total_pln: package_total_pln,
            package_weight: package_weight
          )
        end
      end

      Result.new(
        xlsx: render_xlsx(rows),
        orders_count: package_seq,
        rows_count: rows.size,
        from_date: @from_date,
        to_date: @to_date
      )
    end

    private

    def render_xlsx(rows)
      package = Axlsx::Package.new
      package.workbook.add_worksheet(name: SHEET_NAME) do |sheet|
        sheet.add_row(HEADERS)
        rows.each { |row| sheet.add_row(row, types: Array.new(HEADERS.size, :string)) }
      end
      package.to_stream.read
    end

    def order_context(order, package_seq)
      user = order.user
      passport = (user&.passport_data || {}).stringify_keys
      serial, number = passport_parts(passport)
      registration = registration_address(user, passport)
      delivery = delivery_fields(order)
      consents = consent_dates(order, user)

      {
        shipment_number: shipment_number(order),
        track_number: order.resolved_track_number.presence || NA,
        package_seq: package_seq,
        package_label: "Package-#{order.id}",
        full_name: recipient_full_name(order, user),
        email: user&.email.presence || NA,
        phone: (order.phone.presence || user&.phone).presence || NA,
        passport_serial: serial.presence || NA,
        passport_number: number.presence || NA,
        passport_date: formatted_date(value(passport, "passport_date", "issued_date", "issued_at", "issue_date")) || NA,
        passport_founder: value(passport, "passport_founder", "issued_by").presence || NA,
        iin: value(passport, "iin", "id_number", "personal_number", "identification_number").presence || NA,
        birthdate: formatted_date(user&.dob.presence || value(passport, "birthdate", "dob", "birth_date", "date_of_birth", "birthday")) || NA,
        delivery: delivery,
        registration: registration,
        consent1: consents[:personal_data],
        consent2: consents[:customs_broker]
      }
    end

    def build_row(order:, item:, line_no:, ctx:, package_total_pln:, package_weight:)
      item.ensure_poland_snapshot!(persist: false)
      unit_pln = item.poland_price_pln
      qty = item.quantity.to_i
      line_pln = unit_pln.present? ? (unit_pln.to_d * qty) : nil
      unit_weight = item_unit_weight_kg(item)
      line_weight = unit_weight.present? ? (unit_weight * qty) : nil
      delivery = ctx[:delivery]
      reg = ctx[:registration]

      [
        ctx[:shipment_number],
        ctx[:track_number],
        ctx[:package_seq],
        ctx[:package_label],
        ctx[:full_name],
        ctx[:email],
        ctx[:phone],
        ctx[:passport_serial],
        ctx[:passport_number],
        ctx[:passport_date],
        ctx[:passport_founder],
        ctx[:iin],
        ctx[:birthdate],
        "", # индекс доставки — по шаблону часто пустой
        delivery[:country],
        delivery[:region],
        delivery[:city],
        delivery[:address],
        delivery[:pvz],
        delivery[:comment],
        product_site_url(item),
        NA, # ТН ВЭД код
        NA, # ТН ВЭД наименование
        line_no,
        item.catalog_title.presence || NA,
        BRAND,
        SIZE,
        qty,
        format_money(unit_pln),
        format_money(line_pln),
        format_money(package_total_pln),
        CURRENCY,
        format_weight(line_weight),
        format_weight(unit_weight),
        format_weight(package_weight),
        "", # инвойс
        order.created_at&.to_date,
        0,
        COD_CURRENCY,
        "", # продавец
        NA, # адрес продавца
        NA, # отправитель
        NA, # адрес отправителя
        SHOP,
        reg["region"].presence || NA,
        reg["city"].presence || NA,
        reg["street"].presence || NA,
        reg["house"].presence || NA,
        reg["building"].presence || "",
        reg["apartment"].presence || "",
        reg["postcode"].presence || NA,
        ctx[:consent1],
        ctx[:consent2],
        PERSONAL_DATA_TEXT,
        CUSTOMS_BROKER_TEXT
      ]
    end

    def shipment_number(order)
      remote = order.poland_track_export&.remote_response
      shop_number = remote.is_a?(Hash) ? remote["shop_number"].presence : nil
      return shop_number if shop_number.present?

      "GP#{order.id.to_s.rjust(9, '0')}PL"
    end

    def recipient_full_name(order, user)
      if user
        name = [user.last_name, user.first_name, user.middle_name].compact_blank.join(" ")
        return name if name.present?
      end
      order.full_name.presence || NA
    end

    def passport_parts(passport)
      serial = value(passport, "passport_serial", "series").to_s.gsub(/\s/, "").upcase
      number = value(passport, "passport_number", "number").to_s.gsub(/\s/, "").upcase
      if serial.empty? && (match = number.match(/\A([A-Z]{2})(\d{7})\z/))
        serial, number = match.captures
      elsif serial.empty? && (match = number.match(/\A(\d{4})(\d{6})\z/))
        serial, number = match.captures
      elsif serial.present? && number.start_with?(serial) && number.length > 7
        number = number.delete_prefix(serial)
      end
      [serial, number]
    end

    def registration_address(user, passport)
      fields = %w[region city street house building apartment postcode]
      profile = fields.to_h { |key| [key, user&.public_send(key)] }
      return profile if profile.values.any?(&:present?)

      passport.slice(*fields)
    end

    def delivery_fields(order)
      root = (order.address_json || {}).deep_stringify_keys
      delivery = root["delivery"].is_a?(Hash) ? root["delivery"] : {}
      address = delivery["address"].is_a?(Hash) ? delivery["address"] : {}
      address = root if address.blank? && root["city"].present?
      pickup = delivery["pickup_point"].is_a?(Hash) ? delivery["pickup_point"] : {}

      city = value(address, "city", "address_city").presence ||
             pickup["city"].presence ||
             root["city"].presence ||
             NA
      street = value(address, "street", "address_street")
      house = value(address, "house", "house_number", "address_house_number")
      corpus = value(address, "building", "corpus")
      apartment = value(address, "apartment", "flat", "flat_number")
      full = value(address, "address_full", "full_address")

      composed =
        if full.present?
          full
        elsif [street, house].any?(&:present?)
          [street, house.present? ? "д. #{house}" : nil,
           corpus.present? ? "корп. #{corpus}" : nil,
           apartment.present? ? "кв. #{apartment}" : nil].compact.join(", ")
        elsif pickup["address"].present? || pickup["name"].present?
          [pickup["name"], pickup["address"]].compact_blank.join(", ")
        else
          NA
        end

      pvz = root["pickup_point_id"].presence ||
            pickup["external_id"].presence ||
            pickup["id"].presence ||
            order.tracking_info&.dig("europost_create", "payload", "store_id_finish")

      country = country_label(order.user&.country_code.presence || order.country)

      {
        country: country,
        region: value(address, "region", "area", "oblast").presence || NA,
        city: city,
        address: composed.presence || NA,
        pvz: pvz.presence || "",
        comment: value(address, "comment", "notes").presence || ""
      }
    end

    def country_label(code)
      raw = code.to_s.strip
      case raw.downcase
      when "by", "rb", "рб", "беларусь" then "Беларусь"
      when "ru", "рф", "россия" then "Россия"
      when "kz", "рк" then "Казахстан"
      when "" then NA
      else
        # Профильные значения: RB / РФ / РК
        { "RB" => "Беларусь", "РФ" => "Россия", "РК" => "Казахстан" }.fetch(raw, raw)
      end
    end

    def consent_dates(order, user)
      {
        personal_data: consent_date_for(order, user, "personal_data") ||
          formatted_datetime(user&.personal_data_consented_at) ||
          formatted_datetime(user&.created_at) ||
          NA,
        customs_broker: consent_date_for(order, user, "customs_broker") ||
          formatted_datetime(order.created_at) ||
          NA
      }
    end

    def consent_date_for(order, user, type)
      records = order.consent_records.select { |r| r.consent_type == type && r.accepted }
      record = records.max_by(&:created_at)
      if record.nil? && user
        record = ConsentRecord.where(user_id: user.id, consent_type: type, accepted: true)
                              .order(created_at: :desc).first
      end
      formatted_datetime(record&.created_at)
    end

    def package_total_pln(items)
      items.sum do |item|
        item.ensure_poland_snapshot!(persist: false)
        next 0.to_d if item.poland_price_pln.blank?

        item.poland_price_pln.to_d * item.quantity.to_i
      end
    end

    def package_weight_kg(order)
      kg = order.weight
      if kg.blank?
        address = (order.address_json || {}).deep_stringify_keys
        kg = address["weight_kg"].presence || address.dig("delivery", "weight_kg")
      end
      if kg.blank? && order.pricing_snapshot.is_a?(Hash)
        snap = order.pricing_snapshot.deep_stringify_keys
        kg = snap["total_weight_kg"].presence || snap.dig("totals", "total_weight_kg")
      end
      kg.present? ? kg.to_f : nil
    end

    def item_unit_weight_kg(item)
      product = item.product
      return nil unless product

      weight = product.packaging_weight_kg
      return weight if weight.present? && weight.to_f.positive?

      raw = product.weight
      raw.present? && raw.to_f.positive? ? raw.to_f : nil
    rescue StandardError
      nil
    end

    def product_site_url(item)
      product = item.product
      if product
        core = product.public_sku.presence || product.sku.to_s.sub(/\As/i, "")
        slug = product.slug.presence || core
        return "#{Seo::PublicSiteUrl.resolve}/product/#{slug}-#{core}/"
      end

      sku = item.product_sku.to_s.sub(/\As/i, "")
      return "#{Seo::PublicSiteUrl.resolve}/product/#{sku}-#{sku}/" if sku.present?

      NA
    end

    def format_money(value)
      return NA if value.nil?

      format("%.2f", value.to_d)
    end

    def format_weight(value)
      return NA if value.nil?

      format("%.3f", value.to_f)
    end

    def formatted_date(value)
      return nil if value.blank?
      return value.strftime("%d.%m.%Y") if value.respond_to?(:strftime)

      raw = value.to_s.strip
      format = raw.match?(/\A\d{4}-\d{2}-\d{2}/) ? "%Y-%m-%d" : "%d.%m.%Y"
      Date.strptime(raw[0, 10], format).strftime("%d.%m.%Y")
    rescue Date::Error, ArgumentError
      nil
    end

    def formatted_datetime(value)
      return nil if value.blank?
      return value.strftime("%d.%m.%Y %H:%M") if value.respond_to?(:strftime)

      formatted_date(value)
    end

    def value(hash, *keys)
      keys.filter_map { |key| hash[key].presence }.first
    end
  end
end

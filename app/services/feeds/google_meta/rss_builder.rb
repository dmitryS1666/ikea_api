module Feeds
  module GoogleMeta
    class RssBuilder
      attr_reader :scope, :settings

      def initialize(scope:, settings:)
        @scope = scope
        @settings = settings
      end

      def self.call(scope:, settings:)
        new(scope: scope, settings: settings).call
      end

      def call
        Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
          xml.rss(version: "2.0", "xmlns:g" => "http://base.google.com/ns/1.0") do
            xml.channel do
              xml.title(channel_title)
              xml.link(settings.base_url_root)
              xml.description("Google / Meta product feed")
              xml.pubDate(Time.current.rfc2822)
              build_items(xml)
            end
          end
        end.to_xml
      end

      private

      def build_items(xml)
        each_presenter do |presenter|
          xml.item do
            xml["g"].id(presenter.id)
            xml["g"].title(presenter.title)
            xml["g"].description(presenter.description)
            xml.link(presenter.link_url)
            xml["g"].image_link(presenter.image_url)
            presenter.additional_image_urls.each do |url|
              xml["g"].additional_image_link(url)
            end
            xml["g"].availability(presenter.availability_for_google)
            xml["g"].price("#{formatted_price(presenter.price_amount)} #{presenter.currency}")
            if presenter.sale_price_amount.present?
              xml["g"].sale_price("#{formatted_price(presenter.sale_price_amount)} #{presenter.currency}")
            end
            xml["g"].condition("new")
            xml["g"].brand(presenter.brand)
            xml["g"].product_type(presenter.product_type) if presenter.product_type.present?
            xml["g"].material(presenter.material) if presenter.material.present?
            xml["g"].pattern(presenter.pattern) if presenter.pattern.present?
            xml["g"].color(presenter.color) if presenter.color.present?
            xml["g"].size(presenter.size) if presenter.size.present?
            xml["g"].item_group_id(presenter.item_group_id) if presenter.item_group_id.present?

            if presenter.gtin.present?
              xml["g"].gtin(presenter.gtin)
            end
            xml["g"].mpn(presenter.mpn) if presenter.mpn.present?

            xml["g"].custom_label_0(presenter.custom_label_0) if presenter.custom_label_0.present?
            xml["g"].custom_label_1(presenter.custom_label_1) if presenter.custom_label_1.present?
            xml["g"].custom_label_2(presenter.custom_label_2) if presenter.custom_label_2.present?
            xml["g"].custom_label_3(presenter.custom_label_3) if presenter.custom_label_3.present?
            xml["g"].custom_label_4(presenter.custom_label_4) if presenter.custom_label_4.present?
          end
        end
      end

      def each_presenter
        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a
        pricing = pricing_context
        categories = Category.all.index_by(&:ikea_id)

        scope.find_each do |product|
          presenter = Feeds::ProductPresenter.new(
            product: product,
            settings: settings,
            pricing_context: pricing,
            active_promos: promos,
            category_index: categories
          )
          next unless presenter.valid?
          next if exclude_out_of_stock?(presenter)

          yield presenter
        end
      end

      def pricing_context
        {
          pln_rate: ExchangeRate.fetch_or_create("PLN")&.rate_per_unit.to_f,
          buffer: PriceCalculationService.exchange_rate_buffer
        }
      end

      def exclude_out_of_stock?(presenter)
        !settings.include_out_of_stock? && presenter.availability_key == "out_of_stock"
      end

      def formatted_price(amount)
        sprintf("%.2f", amount)
      end

      def channel_title
        settings.store_name.presence || "Product feed"
      end
    end
  end
end

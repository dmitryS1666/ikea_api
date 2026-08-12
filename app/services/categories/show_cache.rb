# frozen_string_literal: true

module Categories
  # Кеш JSON для GET /api/v1/categories/:id.
  # Основной выигрыш — не пересчитывать available_filters/children на каждый запрос.
  # После ночного обновления цен/наличия прогреваем warm_many!, чтобы утро не било cold path.
  class ShowCache
    PREFIX = "category_show_v1"
    TTL = 26.hours

    class << self
      def fetch(ikea_id:, city:, site_url:)
        ikea_id = ikea_id.to_s
        return nil if ikea_id.blank?

        Rails.cache.fetch(
          cache_key(ikea_id: ikea_id, city: city, site_url: site_url),
          expires_in: TTL,
          skip_nil: true
        ) do
          build_payload(ikea_id: ikea_id, city: city, site_url: site_url)
        end
      end

      def warm!(ikea_id:, city:, site_url:)
        ikea_id = ikea_id.to_s
        return nil if ikea_id.blank?

        payload = build_payload(ikea_id: ikea_id, city: city, site_url: site_url)
        return nil if payload.blank?

        Rails.cache.write(
          cache_key(ikea_id: ikea_id, city: city, site_url: site_url),
          payload,
          expires_in: TTL
        )
        payload
      end

      def warm_many!(ikea_ids:, city:, site_url:)
        Array(ikea_ids).map(&:to_s).reject(&:blank?).uniq.filter_map do |id|
          warm!(ikea_id: id, city: city, site_url: site_url)
        rescue StandardError => e
          Rails.logger.warn(
            "[Categories::ShowCache] warm failed for #{id}: #{e.class} #{e.message}"
          )
          nil
        end
      end

      def bust!(ikea_id)
        return if ikea_id.blank?

        delete_matched("#{PREFIX}_#{ikea_id}_*")
      end

      def bust_all!
        delete_matched("#{PREFIX}_*")
      end

      private

      def build_payload(ikea_id:, city:, site_url:)
        record = Category
                 .includes(:seo_meta)
                 .with_attached_icon
                 .with_attached_background_image
                 .find_by(ikea_id: ikea_id.to_s)

        return nil unless record

        CategorySerializer.new(record, {
          params: { city: city, site_url: site_url }
        }).serializable_hash
      end

      def cache_key(ikea_id:, city:, site_url:)
        pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit
        buffer = CalculatorSetting.get("exchange_rate_buffer")
        fingerprint = Digest::SHA1.hexdigest([site_url, pln_rate, buffer].join("|"))[0, 12]

        [
          PREFIX,
          ikea_id,
          city.to_s.presence || "default",
          fingerprint
        ].join("_")
      end

      def delete_matched(pattern)
        return unless Rails.cache.respond_to?(:delete_matched)

        Rails.cache.delete_matched(pattern)
      rescue StandardError => e
        Rails.logger.warn("[Categories::ShowCache] delete_matched failed: #{e.class} #{e.message}")
      end
    end
  end
end

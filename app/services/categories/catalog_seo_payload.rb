# frozen_string_literal: true

module Categories
  class CatalogSeoPayload
    TARGET_TYPE = "catalog"

    class << self
      def call
        setting = GlobalSeoSetting.for(TARGET_TYPE)
        return nil unless setting

        payload = {
          title: sanitized_meta(setting.h1_template),
          meta_title: sanitized_meta(setting.title_template),
          meta_description: sanitized_meta(setting.description_template),
          seo_text: setting.seo_text.to_s.presence
        }

        payload.values.any?(&:present?) ? payload : nil
      end

      private

      def sanitized_meta(value)
        return nil if value.blank?

        ActionController::Base.helpers.strip_tags(value).squish.presence
      end
    end
  end
end

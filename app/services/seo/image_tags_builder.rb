# frozen_string_literal: true

module Seo
  class ImageTagsBuilder
    DEFAULT_ALT_TEMPLATE = "{{name}} — фото {{index}}"
    DEFAULT_TITLE_TEMPLATE = "{{name}}"

    def self.for_product(product, city_code = nil)
      new(product, city_code).build
    end

    def initialize(product, city_code = nil)
      @product = product
      @city_code = city_code
    end

    def build
      urls = ProductLocalImages.expand_paths(product.local_images)
      return [] if urls.blank?

      urls.each_with_index.map do |url, index|
        {
          url: url,
          alt: render_tag(alt_template, index),
          title: render_tag(title_template, index)
        }
      end
    end

    private

    attr_reader :product, :city_code

    def alt_template
      personal = product.seo_meta&.image_alt.presence
      return personal if personal

      global = GlobalSeoSetting.for("product")
      global&.image_alt_template.presence || DEFAULT_ALT_TEMPLATE
    end

    def title_template
      personal = product.seo_meta&.image_title.presence
      return personal if personal

      global = GlobalSeoSetting.for("product")
      global&.image_title_template.presence || DEFAULT_TITLE_TEMPLATE
    end

    def render_tag(template, index)
      SeoHelper.render_template_string(template, product, city_code)
        .gsub("{{index}}", (index + 1).to_s)
    end
  end
end

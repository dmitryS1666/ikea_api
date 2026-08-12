class CategorySerializer
  include FastJsonapi::ObjectSerializer

  set_id :ikea_id

  attribute :slug do |category|
    category.slug
  end

  attributes :translated_name,
             :local_image_path,
             :is_deleted,
             :is_important,
             :is_popular,
             :popular_position,
             :is_top,
             :top_position,
             :is_custom,
             :header_menu,
             :header_menu_position,
             :delivery_days,
             :is_bulky,
             :show_delivery_block,
             :show_reviews_block,
             :show_tips_block,
             :icon_url,
             :pictogram_url,
             :background_image_url,
             :available_filters

  attribute :icon_url do |category|
    ActiveStorageStaticPublisher.url_for(category.icon)
  end

  attribute :pictogram_url do |category|
    ActiveStorageStaticPublisher.url_for(category.pictogram)
  end

  attribute :background_image_url do |category|
    ActiveStorageStaticPublisher.url_for(category.background_image)
  end

  attribute :parent_ids do |category|
    category.parent_ids || []
  end

  attribute :children do |category|
    serialize_children(category.children)
  end

  attribute :available_filters do |category|
    category.display_filters_for_api
  end

  attribute :seo do |category, params|
    SeoHelper.meta_for(category, params[:city])
  end

  class << self
    private

    def serialize_children(children)
      children.map do |child|
        {
          ikea_id: child.ikea_id,
          name: child.name,
          translated_name: child.translated_name,
          slug: child.slug,
          icon_url: attachment_url(child, :icon),
          is_deleted: child.is_deleted,
          is_important: child.is_important,
          is_popular: child.is_popular,
          parent_ids: child.parent_ids || [],
          children: serialize_children(child.children)
        }
      end
    end

    def attachment_url(record, attachment_name)
      ActiveStorageStaticPublisher.url_for(record.public_send(attachment_name))
    end
  end
end

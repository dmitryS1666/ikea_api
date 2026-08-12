class HomeBannerSerializer
  include FastJsonapi::ObjectSerializer

  attributes :section,
             :slot_key,
             :breakpoint,
             :variant,
             :position,
             :active,
             :updated_at

  attribute :image_url do |banner|
    ActiveStorageStaticPublisher.url_for(banner.image)
  end

  attribute :link_url do |banner|
    banner.final_link
  end

  attribute :width do |banner|
    banner.expected_dimensions&.first
  end

  attribute :height do |banner|
    banner.expected_dimensions&.last
  end
end

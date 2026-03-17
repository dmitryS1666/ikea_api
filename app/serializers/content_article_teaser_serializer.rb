class ContentArticleTeaserSerializer
  include FastJsonapi::ObjectSerializer

  set_id :slug

  attributes :title, :slug, :excerpt, :content_type, :published_at

  attribute :image_url do |article|
    # Пытаемся взять первое изображение из блоков для превью
    first_block = Array.wrap(article.body_blocks).first
    if first_block && first_block["images"].present?
      signed_id = first_block["images"].first["signed_id"]
      article.preview_url_for(signed_id) if signed_id.present?
    end
  end
end

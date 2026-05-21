# frozen_string_literal: true

module ProductReviews
  class IndexService
    PER_PAGE_DEFAULT = 20
    PER_PAGE_MAX = 50
    SORT_OPTIONS = %w[newest oldest rating_high rating_low helpful].freeze

    def initialize(product:, params: {})
      @product = product
      @params = params
    end

    def call
      page = [params[:page].to_i, 1].max
      per_page = normalized_per_page
      base_scope = Review.published.where(product_sku: @product.sku)
      filtered_scope = apply_filters(base_scope)
      sorted_scope = apply_sort(filtered_scope)

      paginated = sorted_scope
                    .includes(:user, :product, photos_attachments: :blob)
                    .page(page)
                    .per(per_page)

      {
        data: paginated.map(&:as_public_json),
        aggregates: aggregates,
        rating_distribution: rating_distribution,
        photos: photos_strip(base_scope),
        meta: {
          page: page,
          per_page: per_page,
          total: paginated.total_count,
          total_pages: paginated.total_pages
        }
      }
    end

    private

    attr_reader :product, :params

    def normalized_per_page
      per_page = (params[:per_page].presence || PER_PAGE_DEFAULT).to_i
      per_page = PER_PAGE_DEFAULT if per_page <= 0
      [per_page, PER_PAGE_MAX].min
    end

    def apply_filters(scope)
      scope = scope.where(rating: params[:rating].to_i) if params[:rating].present?
      scope = scope.with_attached_photos.joins(:photos_attachments).distinct if truthy?(params[:with_photo])
      scope
    end

    def apply_sort(scope)
      case params[:sort].to_s
      when 'oldest'
        scope.order(pinned: :desc, published_at: :asc, created_at: :asc)
      when 'rating_high'
        scope.order(pinned: :desc, rating: :desc, published_at: :desc, created_at: :desc)
      when 'rating_low'
        scope.order(pinned: :desc, rating: :asc, published_at: :desc, created_at: :desc)
      when 'helpful'
        scope.left_joins(:review_helpful_votes)
             .group('reviews.id')
             .order(
               Arel.sql(
                 'reviews.pinned DESC, COUNT(review_helpful_votes.id) DESC, ' \
                 'COALESCE(reviews.published_at, reviews.created_at) DESC'
               )
             )
      else
        scope.order(pinned: :desc, published_at: :desc, created_at: :desc)
      end
    end

    def aggregates
      {
        rating_avg: product.rating_avg.to_f,
        rating_weighted: product.rating_weighted.to_f,
        rating_count: product.rating_count
      }
    end

    def rating_distribution
      counts = Review.published_reviews.where(product_sku: product.sku).group(:rating).count
      (1..5).each_with_object({}) do |stars, hash|
        hash[stars.to_s] = counts[stars] || 0
      end
    end

    def photos_strip(scope)
      scope
        .with_attached_photos
        .includes(photos_attachments: :blob)
        .order(Arel.sql('COALESCE(reviews.published_at, reviews.created_at) DESC'))
        .flat_map(&:photos_urls)
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end

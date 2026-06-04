# frozen_string_literal: true

module ProductReviews
  class IndexService
    PER_PAGE_DEFAULT = 20
    PER_PAGE_MAX = 50
    SORT_OPTIONS = %w[newest oldest rating_high rating_low helpful].freeze

    class InvalidParameterError < StandardError
      attr_reader :param, :value

      def initialize(param, value, allowed_values: nil)
        @param = param
        @value = value
        allowed = Array(allowed_values).presence
        details = allowed ? "; allowed values: #{allowed.join(', ')}" : nil

        super("Invalid #{param}: #{value.inspect}#{details}")
      end
    end

    def initialize(product:, params: {})
      @product = product
      @params = params
    end

    def call
      page = normalized_page
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
        aggregates: aggregates(filtered_scope),
        rating_distribution: rating_distribution(filtered_scope),
        photos: photos_strip(filtered_scope),
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

    def normalized_page
      page = (params[:page].presence || 1).to_i
      page.positive? ? page : 1
    end

    def normalized_per_page
      per_page = (params[:per_page].presence || PER_PAGE_DEFAULT).to_i
      per_page = PER_PAGE_DEFAULT if per_page <= 0
      [per_page, PER_PAGE_MAX].min
    end

    def apply_filters(scope)
      rating = rating_filter_value
      scope = scope.where(rating: rating) if rating
      scope = only_with_photos(scope) if truthy?(params[:with_photo])
      scope
    end

    def apply_sort(scope)
      case sort_value
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

    def rating_filter_value
      return nil if params[:rating].blank?

      rating = Integer(params[:rating].to_s, 10)
      return rating if (1..5).cover?(rating)

      raise InvalidParameterError.new(:rating, params[:rating], allowed_values: 1..5)
    rescue ArgumentError, TypeError
      raise InvalidParameterError.new(:rating, params[:rating], allowed_values: 1..5)
    end

    def sort_value
      sort = params[:sort].presence || 'newest'
      return sort if SORT_OPTIONS.include?(sort)

      raise InvalidParameterError.new(:sort, params[:sort], allowed_values: SORT_OPTIONS)
    end

    def only_with_photos(scope)
      photos_attachment_ids = ActiveStorage::Attachment
                              .where(record_type: Review.name, name: 'photos')
                              .select(:record_id)

      scope.where(id: photos_attachment_ids)
    end

    def aggregates(scope)
      rating_scope = scope.where(excluded_from_rating: false)
      count = rating_scope.count

      return empty_aggregates if count.zero?

      {
        rating_avg: rating_scope.average(:rating).to_f.round(2),
        rating_weighted: weighted_rating(rating_scope).round(2).to_f,
        rating_count: count
      }
    end

    def empty_aggregates
      {
        rating_avg: 0,
        rating_weighted: 0,
        rating_count: 0
      }
    end

    def weighted_rating(scope)
      settings = ReviewSetting.instance
      base_weight = settings.base_weight.to_d
      helpful_weight_factor = settings.helpful_weight_factor.to_d
      helpful_counts = ReviewHelpfulVote.where(review_id: scope.select(:id)).group(:review_id).count

      total_weight = 0.to_d
      weighted_sum = 0.to_d

      scope.select(:id, :rating).find_each do |review|
        helpful = helpful_counts[review.id] || 0
        weight = base_weight + helpful * helpful_weight_factor
        total_weight += weight
        weighted_sum += review.rating * weight
      end

      total_weight.positive? ? weighted_sum / total_weight : 0.to_d
    end

    def rating_distribution(scope)
      counts = scope.where(excluded_from_rating: false).group(:rating).count
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

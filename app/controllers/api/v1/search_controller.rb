module Api
  module V1
    class SearchController < ApplicationController
      include FavoriteHelper

      def suggest
        query = params[:q].to_s.strip
        page = normalized_page
        per_page = normalized_per_page
        first_page = page == 1

        popular_queries = first_page ? PopularSearchQuery.active.matching(query).ordered.limit(5) : []
        suggestions = first_page ? suggestions_for(query, popular_queries: popular_queries) : []

        all_matching_products_scope = search_scope(query)
        paginated_products_scope = paginated_search_scope(all_matching_products_scope, query)

        display_products = paginated_products_scope
                             .includes(:category, :categories, :seo_meta)
                             .page(page)
                             .per(per_page)

        suggest_categories =
          if first_page
            Search::SuggestCategoryResolver.new(
              query,
              products: display_products,
              products_scope: all_matching_products_scope
            ).call
          else
            []
          end

        combined_categories = categories_from_suggest_payload(suggest_categories)

        available_filters = first_page ? aggregate_filters_for(all_matching_products_scope, combined_categories) : []

        log_search(query, display_products.total_count) if first_page && query.present?

        rates = {
          eur: ExchangeRate.fetch_or_create('EUR')&.rate_per_unit,
          pln: ExchangeRate.fetch_or_create('PLN')&.rate_per_unit
        }

        calculator_settings = {
          'show_delivery_block_global' => CalculatorSetting.get('show_delivery_block_global'),
          'show_reviews_block_global' => CalculatorSetting.get('show_reviews_block_global'),
          'show_tips_block_global' => CalculatorSetting.get('show_tips_block_global'),
          'default_delivery_days' => CalculatorSetting.get('default_delivery_days'),
          'exchange_rate_buffer' => CalculatorSetting.get('exchange_rate_buffer')
        }

        promos = PromoCode.active_now.includes(:promo_code_products, :promo_code_categories).to_a

        render json: {
          suggestions: suggestions,
          categories: suggest_categories,
          products: ProductTeaserSerializer.new(display_products, {
            params: {
              favorite_skus: current_favorite_skus,
              active_promos: promos,
              promo_applicability: get_promo_applicability(display_products, promos),
              rates: rates,
              calculator_settings: calculator_settings
            }
          }).serializable_hash,
          available_filters: available_filters,
          popular_queries: popular_queries.map do |entry|
            { query: entry.query, weight: entry.weight }
          end,
          meta: {
            total: display_products.total_count,
            page: page,
            per_page: per_page,
            total_pages: display_products.total_pages
          }
        }
      end

      private

      def normalized_sku_query(query)
        query.to_s.gsub(/[^[:alnum:]]/, '')
      end

      def categories_from_suggest_payload(suggest_categories)
        ids = Array(suggest_categories).filter_map { |entry| entry[:id] || entry["id"] }.map(&:to_s).uniq
        return [] if ids.blank?

        by_id = Category.active.where(ikea_id: ids).index_by { |c| c.ikea_id.to_s }
        ids.filter_map { |ikea_id| by_id[ikea_id] }
      end

      def normalized_page
        page = params[:page].to_i
        page > 0 ? page : 1
      end

      def normalized_per_page
        per_page = params[:per_page].to_i
        per_page = 20 if per_page <= 0
        [per_page, 100].min
      end

      def search_scope(query)
        return Product.none if query.blank?
      
        term = "%#{query}%"
        sku_query = normalized_sku_query(query)
      
        if sku_query.present?
          Product.with_available_stock.where(
            "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term OR sku ILIKE :term OR regexp_replace(sku, '[^A-Za-z0-9]', '', 'g') ILIKE :sku_term",
            term: term,
            sku_term: "%#{sku_query}%"
          )
        else
          Product.with_available_stock.where(
            "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term OR sku ILIKE :term",
            term: term
          )
        end
      end

      def paginated_search_scope(scope, query)
        return Product.none if query.blank?
      
        case params[:sort].to_s
        when 'cheapest'
          scope.order('products.price ASC')
        when 'expensive'
          scope.order('products.price DESC')
        when 'newest'
          scope.order('products.created_at DESC')
        when 'popular'
          scope.order(Arel.sql('products.popularity_score DESC, products.rating_weighted DESC, products.views_count DESC'))
        else
          apply_default_search_order(scope, query)
        end
      end

      def apply_default_search_order(scope, query)
        normalized_query = normalized_sku_query(query).downcase
      
        exact_sku_sql = ApplicationRecord.sanitize_sql_array(
          ["CASE WHEN LOWER(regexp_replace(products.sku, '[^A-Za-z0-9]', '', 'g')) = ? THEN 0 ELSE 1 END", normalized_query]
        )
      
        scope.order(
          Arel.sql("#{exact_sku_sql}, products.id DESC")
        )
      end

      def aggregate_filters_for(products_scope, categories)
        return [] if products_scope.blank? || categories.blank?

        counts = ProductFilterValue.where(product_id: products_scope.select(:id))
                                   .group(:parameter, :value_id)
                                   .count

        param_to_values = {}
        counts.each do |(param, value_id), count|
          param_to_values[param] ||= {}
          param_to_values[param][value_id.to_s] = count
        end

        aggregated = {}

        categories.each do |category|
          filters_to_use =
            if category.respond_to?(:display_filters_for_api)
              category.display_filters_for_api
            else
              category.available_filters || []
            end
          next if filters_to_use.blank?

          filters_to_use.each do |filter|
            param = filter["parameter"]
            next unless param_to_values.key?(param)

            matching_values = Array(filter["values"]).filter_map do |v|
              value_id = v["id"].to_s
              count = param_to_values[param][value_id]
              next if count.nil? || count.zero?

              v.merge("count" => count)
            end

            next if matching_values.empty?

            if aggregated[param]
              existing_values = aggregated[param]["values"]
              existing_ids = existing_values.map { |v| v["id"].to_s }.to_set

              matching_values.each do |v|
                unless existing_ids.include?(v["id"].to_s)
                  existing_values << v
                end
              end
            else
              aggregated[param] = {
                "parameter" => param,
                "name" => filter["name"],
                "values" => matching_values
              }
            end
          end
        end

        aggregated.values
      end

      def suggestions_for(query, popular_queries: nil)
        return [] if query.blank?

        popular_queries = Array(popular_queries)
        normalized_query = query.downcase
        query_suggestions = popular_queries.map(&:query)
                                          .compact
                                          .map(&:strip)
                                          .reject(&:blank?)
                                          .select { |entry| entry.downcase.include?(normalized_query) }

        # Если уже набралось достаточно "поисковых связок", не смешиваем их с товарами.
        return query_suggestions.uniq.first(5) if query_suggestions.size >= 5

        term = "%#{query}%"
        # Расширенный список аксессуаров и текстиля, которые нужно понизить в выдаче
        accessory_keywords = %w[чехол аксессуар ножки подушка каркас подлокотник простыня наволочка пододеяльник матрас подзор наматрасник ящик изголовье днище покрывало плед одеяло]
        
        # Находим категории, которые начинаются с запроса, чтобы повысить товары из них
        top_matching_categories = Category.active.where("translated_name ILIKE ?", "#{query}%").pluck(:ikea_id).map(&:to_s)

        products = Product.with_available_stock.where(
          "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term",
          term: term
        )
                          .limit(100)

        product_suggestions = products.map do |p|
          display_name = p.small_desc_name.presence || p.name.presence
          next if display_name.blank?

          # Оцениваем, является ли товар аксессуаром
          is_accessory = accessory_keywords.any? { |kw| display_name.downcase.include?(kw) }
          
          # Базовый приоритет: 0 для прямых товаров, 1 для аксессуаров
          priority = is_accessory ? 1 : 0
          
          # Если товар принадлежит к категории, которая начинается с запроса — значительно повышаем приоритет (-2)
          priority -= 2 if top_matching_categories.include?(p.category_id.to_s)
          
          # Дополнительный приоритет, если название начинается с запроса (-1)
          priority -= 1 if display_name.downcase.start_with?(query.downcase)
          # Или содержит запрос как отдельное слово (-1)
          priority -= 1 if display_name.downcase.include?(" #{query.downcase}")

          { name: display_name.strip, priority: priority }
        end.compact
           .uniq { |s| s[:name] }
           .sort_by { |s| [s[:priority], s[:name]] }
           .take(5)
           .map { |s| s[:name] }

        (query_suggestions + product_suggestions).uniq.first(5)
      end

      def log_search(query, results_count)
        SearchQueryLog.create!(
          customer: current_user,
          query: query,
          results_count: results_count
        )
      end
    end
  end
end

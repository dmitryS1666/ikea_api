module Api
  module V1
    class SearchController < ApplicationController
      include FavoriteHelper
      
      def suggest
        query = params[:q].to_s.strip
        suggestions = suggestions_for(query)
        popular_queries = PopularSearchQuery.active.matching(query).ordered.limit(5)
        
        # 1. Находим продукты
        display_products = prioritized_products(query)
        # Получаем ID всех продуктов, подходящих под поиск, для корректного подсчета фильтров
        all_matching_products_scope = search_scope(query)

        # 2. Категории: те, что совпали по имени + те, где есть найденные продукты
        matched_categories = matching_categories(query)
        product_categories = get_product_categories(display_products)
        combined_categories = (matched_categories.to_a + product_categories.to_a).uniq(&:ikea_id)

        # 3. Фильтры с подсчетом (на основе всех подходящих продуктов)
        available_filters = aggregate_filters_for(all_matching_products_scope, combined_categories)

        log_search(query, display_products.size) if query.present?

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
          categories: combined_categories.map do |category|
            {
              id: category.ikea_id,
              slug: category.slug,
              translated_name: category.translated_name,
              local_image_path: category.local_image_path
            }
          end,
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
          end
        }
      end

      private

      def search_scope(query)
        return Product.none if query.blank?
        
        Product.where(
          "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term OR sku ILIKE :term",
          term: "%#{query}%"
        )
      end

      def get_product_categories(products)
        return [] if products.blank?

        products.flat_map { |p| p.categories.to_a + [p.category].compact }.uniq
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
          filters_to_use = category.respond_to?(:display_filters) ? category.display_filters : (category.available_filters || [])
          next if filters_to_use.blank?
          
          filters_to_use.each do |filter|
            param = filter["parameter"]
            next unless param_to_values.key?(param)
            
            matching_values = Array(filter["values"]).filter_map do |v|
              value_id = v["id"].to_s
              count = param_to_values[param][value_id]
              next if count.nil? || count == 0
              
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

      def suggestions_for(query)
        return [] if query.blank?

        pattern = "#{query}%"
        products = Product.where(
                            "name_ru ILIKE :pattern OR small_desc_name ILIKE :pattern",
                            pattern: pattern
                          ).limit(30)
        categories = Category.where("translated_name ILIKE :pattern", pattern: pattern)
                             .limit(20)

        names = products.map(&:name_ru)
        names += products.map(&:small_desc_name)
        names += categories.map(&:translated_name)

        names.compact.map(&:strip).reject(&:blank?).uniq.take(5)
      end

      def matching_categories(query)
        return Category.none if query.blank?

        Category.active
                .where("name ILIKE :term OR translated_name ILIKE :term", term: "%#{query}%")
                .limit(5)
      end

      def prioritized_products(query)
        return Product.none if query.blank?

        exact_matches = Product.includes(:category, :categories, :seo_meta)
                               .where("LOWER(sku) = ?", query.downcase)
                               .limit(1)
                               .to_a
        exact_ids = exact_matches.map(&:id)

        fuzzies = Product.includes(:category, :categories, :seo_meta)
                         .where(
                           "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term",
                           term: "%#{query}%"
                         )
                         .where.not(id: exact_ids)
                         .limit([10 - exact_matches.size, 0].max)

        (exact_matches + fuzzies.to_a).take(10)
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

module Api
  module V1
    class SearchController < ApplicationController
      include FavoriteHelper

      def suggest
        query = params[:q].to_s.strip
        page = normalized_page
        per_page = normalized_per_page

        suggestions = suggestions_for(query)
        popular_queries = PopularSearchQuery.active.matching(query).ordered.limit(5)

        all_matching_products_scope = search_scope(query)
        paginated_products_scope = paginated_search_scope(all_matching_products_scope, query)

        display_products = paginated_products_scope
                             .includes(:category, :categories, :seo_meta)
                             .page(page)
                             .per(per_page)

        matched_categories = matching_categories(query)
        product_categories = get_product_categories(display_products)
        combined_categories = (matched_categories.to_a + product_categories.to_a).uniq(&:ikea_id)

        available_filters = aggregate_filters_for(all_matching_products_scope, combined_categories)

        log_search(query, all_matching_products_scope.count) if query.present?

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
          categories: serialized_category_tree(combined_categories),
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

      def serialized_category_tree(categories)
        categories = Array(categories).compact
        return [] if categories.blank?
      
        categories_for_tree = expand_categories_with_ancestors(categories)
        tree_nodes = Category.build_tree(categories_for_tree, sort_roots_by_position: true)
      
        serialize_category_tree_nodes(tree_nodes)
      end
      
      def expand_categories_with_ancestors(categories)
        result = {}
        queue = categories.compact.uniq { |category| category.ikea_id.to_s }
      
        queue.each do |category|
          result[category.ikea_id.to_s] = category
        end
      
        queue.each do |category|
          Category.normalize_parent_ids(category.parent_ids).each do |parent_id|
            next if parent_id.to_s == category.ikea_id.to_s
            next if result.key?(parent_id.to_s)
      
            parent = Category.find_by(ikea_id: parent_id)
            result[parent.ikea_id.to_s] = parent if parent
          end
        end
      
        result.values
      end
      
      def serialize_category_tree_nodes(nodes)
        nodes.map do |node|
          category = node[:category]
      
          {
            id: category.ikea_id,
            slug: category.slug,
            translated_name: category.translated_name,
            local_image_path: category.local_image_path,
            children: serialize_category_tree_nodes(node[:children] || [])
          }
        end
      end

      def normalized_page
        page = params[:page].to_i
        page > 0 ? page : 1
      end

      def normalized_per_page
        per_page = params[:per_page].to_i
        per_page = 50 if per_page <= 0
        [per_page, 100].min
      end

      def search_scope(query)
        return Product.none if query.blank?
      
        term = "%#{query}%"
        sku_query = normalized_sku_query(query)
      
        if sku_query.present?
          Product.where(
            "name ILIKE :term OR name_ru ILIKE :term OR small_desc_name ILIKE :term OR sku ILIKE :term OR regexp_replace(sku, '[^A-Za-z0-9]', '', 'g') ILIKE :sku_term",
            term: term,
            sku_term: "%#{sku_query}%"
          )
        else
          Product.where(
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

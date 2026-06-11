module Api
  module V1
    class DeliveryController < ApplicationController
      include CartResponseFormatter
      DELIVERY_PROVIDERS = ["europost"].freeze

      before_action :authenticate_user_optional

      # GET /api/v1/delivery/types
      def types
        render json: {
          types: [
            { key: DeliveryTypeNormalizer::EUROPOST_PICKUP, name: "Пункт выдачи Европочты" },
            { key: DeliveryTypeNormalizer::COURIER, name: "Курьер" },
            { key: DeliveryTypeNormalizer::IKEYA_DELIVERY, name: "Доставка IKEYA" }
          ],
          providers: DELIVERY_PROVIDERS
        }
      end

      # POST /api/v1/delivery/calculate
      # Context: order_id > items (+ cart_token subset) > cart_token. See DeliveryCartContext.
      def calculate
        unless DeliveryCartContext.context_required?(params)
          return render json: {
            error: "Укажите order_id, cart_token или items",
            code: "delivery_context_required"
          }, status: :unprocessable_entity
        end

        cart_for_options = resolve_delivery_cart
        delivery_type = params[:delivery_type].to_s
        normalized_delivery_type = DeliveryTypeNormalizer.normalize(params[:delivery_type])
        options = DeliveryOptionsService.call(cart_for_options)
        selected_method = options[:methods].find { |m| m[:code] == normalized_delivery_type }

        if selected_method.nil?
          return render json: {
            error: "Неподдерживаемый тип доставки",
            delivery_type: delivery_type,
            normalized_delivery_type: normalized_delivery_type
          }, status: :unprocessable_entity
        end

        unless selected_method[:available]
          return render json: {
            error: "Выбранный тип доставки недоступен для текущей корзины",
            delivery_type: delivery_type,
            normalized_delivery_type: normalized_delivery_type,
            reason: selected_method[:reason],
            available_methods: options[:methods]
          }, status: :unprocessable_entity
        end

        eta = DeliveryEtaService.call(
          order_date: Date.current,
          with_storage: normalized_delivery_type == DeliveryTypeNormalizer::EUROPOST_PICKUP
        )
        display_totals = calculation_totals(cart_for_options)
        weight_kg = display_totals[:total_weight_kg].to_f
        subtotal_byn = display_totals[:subtotal_new_byn].to_f
        discount_total_byn = display_totals[:discount_total_byn].to_f
        cart_delivery_to_belarus_byn = display_totals[:delivery_to_belarus_byn].to_f.round(2)

        pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
        buffer = PriceCalculationService.exchange_rate_buffer
        pln_rate_with_buffer = pln_rate * buffer

        finance = DeliveryCalculateFinance.call(
          normalized_delivery_type: normalized_delivery_type,
          weight_kg: weight_kg,
          pln_rate_with_buffer: pln_rate_with_buffer,
          parcels: options[:parcels],
          pickup_point_id: params[:pickup_point_id],
          address: delivery_calculate_address_param
        )

        method_delivery_byn = finance[:delivery_price_byn].to_f.round(2)
        delivery_total_byn = (cart_delivery_to_belarus_byn + method_delivery_byn).round(2)
        order_total_byn = [(subtotal_byn - discount_total_byn + delivery_total_byn), 0.0].max.round(2)

        rules = CartRulesService.call(subtotal_new_byn: subtotal_byn)
        pp_eval = pickup_point_evaluation(params[:pickup_point_id], options[:parcels], weight_kg)

        render json: {
          basis: {
            total_weight_kg: weight_kg,
            subtotal_byn: sprintf("%.2f", subtotal_byn),
            discount_total_byn: sprintf("%.2f", discount_total_byn)
          },
          totals: {
            items_total_byn: sprintf("%.2f", subtotal_byn),
            subtotal_new_byn: sprintf("%.2f", subtotal_byn),
            discount_total_byn: sprintf("%.2f", discount_total_byn),
            delivery_to_belarus_byn: sprintf("%.2f", cart_delivery_to_belarus_byn),
            delivery_method_byn: sprintf("%.2f", method_delivery_byn),
            delivery_total_byn: sprintf("%.2f", delivery_total_byn),
            total_byn: sprintf("%.2f", order_total_byn),
            final_total_byn: sprintf("%.2f", order_total_byn)
          },
          delivery_total_byn: sprintf("%.2f", delivery_total_byn),
          delivery_to_belarus_byn: sprintf("%.2f", cart_delivery_to_belarus_byn),
          delivery_method_byn: sprintf("%.2f", method_delivery_byn),
          total_byn: sprintf("%.2f", order_total_byn),
          final_total_byn: sprintf("%.2f", order_total_byn),
          delivery: {
            type: normalized_delivery_type,
            eta: {
              delivery_date: eta[:delivery_date],
              storage_until: eta[:storage_until]
            },
            base_cost_byn: sprintf("%.2f", finance[:base_cost_byn]),
            poland_delivery_byn: sprintf("%.2f", finance[:poland_delivery_byn]),
            belarus_delivery_byn: sprintf("%.2f", cart_delivery_to_belarus_byn),
            free_delivery_threshold_byn: sprintf("%.2f", rules[:rules][:free_delivery_threshold_byn]),
            free_delivery_eligible: subtotal_byn >= rules[:rules][:free_delivery_threshold_byn],
            free_delivery_missing_byn: sprintf("%.2f", rules[:flags][:free_delivery_missing_byn]),
            delivery_type: delivery_type,
            normalized_delivery_type: normalized_delivery_type,
            available: selected_method[:available],
            delivery_date: eta[:delivery_date],
            storage_until: eta[:storage_until],
            delivery_price_byn: sprintf("%.2f", finance[:delivery_price_byn]),
            delivery_to_belarus_price_byn: sprintf("%.2f", cart_delivery_to_belarus_byn),
            total_delivery_price_byn: sprintf("%.2f", delivery_total_byn),
            delivery_total_byn: sprintf("%.2f", delivery_total_byn),
            delivery_to_belarus_byn: sprintf("%.2f", cart_delivery_to_belarus_byn),
            pricing: delivery_calculate_pricing_json(finance),
            display: {
              title: "Доставка",
              subtitle: normalized_delivery_type,
              total_delivery_price_byn: sprintf("%.2f", delivery_total_byn),
              total_byn: sprintf("%.2f", order_total_byn)
            }
          },
          pickup_point: pp_eval
        }
      rescue DeliveryCartContext::Error => e
        render json: e.as_json, status: e.http_status
      end

      # GET /api/v1/delivery/europost_offices
      # Without order_id / cart_token / items: public catalog for /pvz (all offices, no cart prices).
      # With delivery context: offices filtered by cart VGH + per-cart delivery prices.
      def europost_offices
        unless DeliveryCartContext.context_required?(params)
          return render_public_europost_offices
        end

        cart = resolve_delivery_cart
        render_filtered_europost_offices_for_cart(cart)
      rescue DeliveryCartContext::Error => e
        render json: e.as_json, status: e.http_status
      end

      private

      def resolve_delivery_cart
        DeliveryCartContext.resolve(params: params, request: request, user: current_user)
      end

      def europost_store_type_param
        EuropostApiService.external_stores_type_param(params[:type])
      end

      def europost_office_payload(office)
        external_id = office["WarehouseId"].to_s
        summary = europost_working_hours(office)
        structured = EuropostWorkingHoursFormatter.structured_for_payload(office)

        payload = {
          id: external_id,
          external_id: external_id,
          name: office["WarehouseName"],
          city: office["Address7Name"],
          address: europost_address(office),
          phone: EuropostOfficePhone.for_office(office),
          lat: office["Latitude"],
          lon: office["Longitude"],
          lng: office["Longitude"],
          provider: "europost",
          max_weight_kg: DeliveryOptionsService.europost_office_weight_limit_kg(office)
        }.merge(structured).merge(working_hours: summary)

        payload[:store_type] = office["store_type"] if office.key?("store_type")
        payload[:ops_number] = office["ops_number"] if office.key?("ops_number")
        payload[:ops_name] = office["ops_name"] if office.key?("ops_name")
        payload[:is_large_weight_limit] = office["is_large_weight_limit"] if office.key?("is_large_weight_limit")
        payload
      end

      def europost_address(office)
        [office["Address5Name"], office["Address4Name"], office["Address3Name"]]
          .map { |value| value.to_s.strip }
          .reject(&:blank?)
          .join(", ")
          .presence
      end

      def europost_working_hours(office)
        EuropostWorkingHoursFormatter.summary_for_payload(office)
      end

      def calculation_totals(cart)
        pricing = CartPricingService.call(cart: cart)
        CartDisplayTotalsService.for_summary(pricing[:totals])
      end

      def pickup_point_evaluation(pickup_point_id, parcels, weight_kg)
        return nil if pickup_point_id.blank?

        office = DeliveryOptionsService.europost_offices.find { |o| o["WarehouseId"].to_s == pickup_point_id.to_s }
        return nil unless office

        eligible = DeliveryOptionsService.europost_office_supports_parcels?(office: office, parcels: parcels)
        payload = europost_office_payload(office)
        payload[:eligible] = eligible
        payload[:reasons] = eligible ? [] : ["max_weight_exceeded"]
        payload
      end

      def render_public_europost_offices
        api_offices = DeliveryOptionsService.europost_offices(europost_store_type: europost_store_type_param)
        api_offices = filter_and_order_europost_offices(api_offices, europost_office_search_query)
        offices = api_offices.map { |office| europost_office_payload(office) }
        render json: { offices: offices }
      end

      def render_filtered_europost_offices_for_cart(cart)
        options = DeliveryOptionsService.call(cart)
        cart_vgh = options[:cart_vgh]
        parcels = options[:parcels]
        eta = DeliveryEtaService.call(order_date: Date.current, with_storage: true)
        pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
        buffer = PriceCalculationService.exchange_rate_buffer
        pln_rate_with_buffer = pln_rate * buffer
        finance = DeliveryCalculateFinance.call(
          normalized_delivery_type: DeliveryTypeNormalizer::EUROPOST_PICKUP,
          weight_kg: cart_vgh[:weight_kg].to_f,
          pln_rate_with_buffer: pln_rate_with_buffer,
          parcels: parcels,
          pickup_point_id: nil
        )

        api_offices = DeliveryOptionsService.europost_offices(europost_store_type: europost_store_type_param)
        api_offices = filter_and_order_europost_offices(api_offices, europost_office_search_query)
        offices = api_offices.filter_map do |office|
          available_for_cart = cart_vgh[:eligible_for_europost] &&
                               DeliveryOptionsService.europost_office_supports_parcels?(office: office, parcels: parcels)
          next unless available_for_cart

          europost_office_payload(office).merge(
            available_for_cart: true,
            delivery_date: eta[:delivery_date],
            storage_until: eta[:storage_until],
            delivery_price_byn: sprintf("%.2f", finance[:delivery_price_byn]),
            delivery_to_belarus_price_byn: sprintf("%.2f", finance[:delivery_to_belarus_price_byn]),
            total_delivery_price_byn: sprintf("%.2f", finance[:total_delivery_price_byn])
          )
        end

        render json: { offices: offices }
      end


      def europost_office_search_query
        params[:city].presence || params[:q].presence || params[:search].presence
      end

      def filter_and_order_europost_offices(offices, query)
        q = normalize_europost_search_text(query)
        return offices if q.blank?

        exact_city_matches = offices.select { |office| normalize_europost_city(office) == q }
        scope = exact_city_matches.any? ? exact_city_matches : offices.select { |office| europost_office_relevance_score(office, q) < 100 }

        scope.sort_by do |office|
          [
            europost_office_relevance_score(office, q),
            normalize_europost_city(office),
            normalize_europost_search_text(office["WarehouseName"] || office[:WarehouseName]),
            office["WarehouseId"].to_s
          ]
        end
      end

      def europost_office_relevance_score(office, normalized_query)
        city = normalize_europost_city(office)
        return 0 if city == normalized_query
        return 10 if city.start_with?(normalized_query)
        return 20 if city.include?(normalized_query)

        name = normalize_europost_search_text(office["WarehouseName"] || office[:WarehouseName])
        address = normalize_europost_search_text(europost_address(office))
        return 30 if name.include?(normalized_query)
        return 40 if address.include?(normalized_query)

        100
      end

      def normalize_europost_city(office)
        normalize_europost_search_text(office["Address7Name"] || office[:Address7Name] || office["city"] || office[:city])
      end

      def normalize_europost_search_text(value)
        value.to_s
             .downcase
             .tr("ё", "е")
             .gsub(/[.,;:\-]+/, " ")
             .gsub(/\b(г|город|д|деревня|п|поселок|посёлок|аг|агрогородок)\b/u, " ")
             .squish
      end

      def delivery_calculate_address_param
        raw = params[:address]
        return nil if raw.blank?

        raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      end

      def delivery_calculate_pricing_json(finance)
        eq = finance[:europost_quote]
        europost =
          if eq.is_a?(Hash)
            {
              success: eq[:success],
              reason: eq[:reason],
              error: eq[:error],
              postal_total_byn: eq[:postal_total_byn]&.then { |v| sprintf("%.2f", v.to_f) },
              currency: eq[:currency],
              request_payload: eq[:payload]
            }.compact
          end

        {
          source: finance[:pricing_source],
          internal: {
            poland_delivery_byn: sprintf("%.2f", finance[:poland_delivery_byn]),
            belarus_delivery_byn: sprintf("%.2f", finance[:belarus_delivery_byn]),
            total_delivery_byn: sprintf("%.2f", finance[:total_internal_byn])
          },
          europost: europost
        }
      end
    end
  end
end

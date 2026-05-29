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
        weight_kg, _, subtotal_byn = calculation_basis(cart_for_options)

        pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
        buffer = PriceCalculationService.exchange_rate_buffer
        pln_rate_with_buffer = pln_rate * buffer

        finance = DeliveryCalculateFinance.call(
          normalized_delivery_type: normalized_delivery_type,
          weight_kg: weight_kg,
          pln_rate_with_buffer: pln_rate_with_buffer,
          parcels: options[:parcels],
          pickup_point_id: params[:pickup_point_id]
        )

        rules = CartRulesService.call(subtotal_new_byn: subtotal_byn)
        pp_eval = pickup_point_evaluation(params[:pickup_point_id], options[:parcels], weight_kg)

        render json: {
          basis: {
            total_weight_kg: weight_kg,
            subtotal_byn: sprintf("%.2f", subtotal_byn)
          },
          delivery_total_byn: sprintf("%.2f", finance[:total_delivery_price_byn]),
          delivery_to_belarus_byn: sprintf("%.2f", finance[:delivery_to_belarus_price_byn]),
          delivery: {
            type: normalized_delivery_type,
            eta: {
              delivery_date: eta[:delivery_date],
              storage_until: eta[:storage_until]
            },
            base_cost_byn: sprintf("%.2f", finance[:base_cost_byn]),
            poland_delivery_byn: sprintf("%.2f", finance[:poland_delivery_byn]),
            belarus_delivery_byn: sprintf("%.2f", finance[:belarus_delivery_byn]),
            free_delivery_threshold_byn: sprintf("%.2f", rules[:rules][:free_delivery_threshold_byn]),
            free_delivery_eligible: subtotal_byn >= rules[:rules][:free_delivery_threshold_byn],
            free_delivery_missing_byn: sprintf("%.2f", rules[:flags][:free_delivery_missing_byn]),
            delivery_type: delivery_type,
            normalized_delivery_type: normalized_delivery_type,
            available: selected_method[:available],
            delivery_date: eta[:delivery_date],
            storage_until: eta[:storage_until],
            delivery_price_byn: sprintf("%.2f", finance[:delivery_price_byn]),
            delivery_to_belarus_price_byn: sprintf("%.2f", finance[:delivery_to_belarus_price_byn]),
            total_delivery_price_byn: sprintf("%.2f", finance[:total_delivery_price_byn]),
            delivery_total_byn: sprintf("%.2f", finance[:total_delivery_price_byn]),
            delivery_to_belarus_byn: sprintf("%.2f", finance[:delivery_to_belarus_price_byn]),
            pricing: delivery_calculate_pricing_json(finance),
            display: {
              title: "Доставка",
              subtitle: normalized_delivery_type,
              total_delivery_price_byn: sprintf("%.2f", finance[:total_delivery_price_byn])
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

      def calculation_basis(cart)
        pricing = CartPricingService.call(cart: cart)
        display_totals = CartDisplayTotalsService.for_summary(pricing[:totals])

        [
          display_totals[:total_weight_kg].to_f,
          0,
          display_totals[:subtotal_new_byn].to_f
        ]
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

module Api
  module V1
    class DeliveryController < ApplicationController
      include CartResponseFormatter
      DELIVERY_PROVIDERS = ["europost"].freeze

      # GET /api/v1/delivery/types
      def types
        render json: {
          types: [
            { key: DeliveryTypeNormalizer::EUROPOST_PICKUP, name: 'Пункт выдачи Европочты' },
            { key: DeliveryTypeNormalizer::COURIER, name: 'Курьер' },
            { key: DeliveryTypeNormalizer::IKEYA_DELIVERY, name: 'Доставка IKEYA' }
          ],
          providers: DELIVERY_PROVIDERS
        }
      end

      # POST /api/v1/delivery/calculate
      # Either provide cart_token or items.
      def calculate
        delivery_type = params[:delivery_type].to_s
        normalized_delivery_type = DeliveryTypeNormalizer.normalize(params[:delivery_type])
        cart_for_options = cart_for_delivery_options
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
        weight_kg, _, subtotal_byn = calculation_basis
        
        # Получаем расчет через новый сервис для консистентности
        # Если у нас только вес (без корзины), PriceCalculationService может помочь
        pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
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
            subtotal_byn: sprintf('%.2f', subtotal_byn)
          },
          delivery: {
            type: normalized_delivery_type,
            eta: {
              delivery_date: eta[:delivery_date],
              storage_until: eta[:storage_until]
            },
            base_cost_byn: sprintf('%.2f', finance[:base_cost_byn]),
            poland_delivery_byn: sprintf('%.2f', finance[:poland_delivery_byn]),
            belarus_delivery_byn: sprintf('%.2f', finance[:belarus_delivery_byn]),
            free_delivery_threshold_byn: sprintf('%.2f', rules[:rules][:free_delivery_threshold_byn]),
            free_delivery_eligible: subtotal_byn >= rules[:rules][:free_delivery_threshold_byn],
            free_delivery_missing_byn: sprintf('%.2f', rules[:flags][:free_delivery_missing_byn]),
            delivery_type: delivery_type,
            normalized_delivery_type: normalized_delivery_type,
            available: selected_method[:available],
            delivery_date: eta[:delivery_date],
            storage_until: eta[:storage_until],
            delivery_price_byn: sprintf('%.2f', finance[:delivery_price_byn]),
            delivery_to_belarus_price_byn: sprintf('%.2f', finance[:delivery_to_belarus_price_byn]),
            total_delivery_price_byn: sprintf('%.2f', finance[:total_delivery_price_byn]),
            pricing: delivery_calculate_pricing_json(finance),
            display: {
              title: "Доставка",
              subtitle: normalized_delivery_type,
              total_delivery_price_byn: sprintf('%.2f', finance[:total_delivery_price_byn])
            }
          },
          pickup_point: pp_eval
        }
      end

      # GET /api/v1/delivery/pickup_points
      def pickup_points
        points = europost_pickup_points
        points = filter_pickup_points_by_city(points, params[:city])
        render json: { pickup_points: points.map { |point| pickup_point_payload(point) } }
      end

      # ... остальное без изменений ...
      def pickup_points_search
        q = params[:query].to_s.strip
        points = europost_pickup_points
        points = filter_pickup_points_by_query(points, q) if q.present?
        render json: { pickup_points: points.first(50).map { |point| pickup_point_payload(point) } }
      end

      def europost_offices
        if params[:cart_id].present?
          return render_filtered_europost_offices_for_cart_id
        end

        if params[:order_id].present?
          return render_filtered_europost_offices_for_order_id
        end

        if europost_offices_cart_context?
          return render_filtered_europost_offices_for_request_context
        end

        offices = DeliveryOptionsService.europost_offices(europost_store_type: europost_store_type_param)
        render json: {
          offices: offices.map { |office| europost_office_payload(office) }
        }
      end

      private

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
        [office['Address5Name'], office['Address4Name'], office['Address3Name']]
          .map { |value| value.to_s.strip }
          .reject(&:blank?)
          .join(', ')
          .presence
      end

      def europost_working_hours(office)
        EuropostWorkingHoursFormatter.summary_for_payload(office)
      end

      def calculation_basis
        if params[:cart_token].present?
          cart, = CartTokenResolver.call(request: request, params: { cart_token: params[:cart_token] })
          pricing = CartPricingService.call(cart: cart)
          subtotal = pricing[:totals][:items_total_byn].to_f
          weight = cart.cart_items.includes(:product).sum { |ci| ci.product.packaging_weight_kg.to_f * ci.quantity }
          volume = cart.cart_items.joins(:product).sum('products.package_volume * cart_items.quantity').to_f
          [weight, volume, subtotal]
        else
          items = Array(params[:items])
          skus = items.map { |i| i[:sku] || i['sku'] }.compact
          products = Product.with_available_stock.where(sku: skus).index_by(&:sku)
          
          # Согласованно с CartPricingService: единая формула цены из PriceCalculationService
          total_pln = 0.0
          total_weight = 0.0
          
          items.each do |i|
            sku = (i[:sku] || i['sku']).to_s
            qty = (i[:quantity] || i['quantity']).to_i
            p = products[sku]
            next unless p && qty.positive?
            
            pln_price = p.price.to_f
            w = p.packaging_weight_kg.to_f
            line_weight = w * qty
            line_total_pln = PriceCalculationService.line_total_pln(
              unit_price_zl: pln_price,
              quantity: qty,
              weight_kg: line_weight,
              delivery_unit_pln: p.delivery_cost.to_f
            )
            total_pln += line_total_pln
            total_weight += line_weight
          end
          
          pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
          buffer = PriceCalculationService.exchange_rate_buffer
          subtotal_byn = (total_pln * pln_rate * buffer).round(2)
          
          [total_weight, 0, subtotal_byn]
        end
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

      def pickup_point_payload(point)
        summary = point[:working_hours]
        structured = EuropostWorkingHoursFormatter.structured_for_payload(point.stringify_keys)

        base = {
          id: point[:id],
          provider: point[:provider],
          name: point[:name],
          city: point[:city],
          address: point[:address],
          phone: point[:phone],
          lat: point[:lat],
          lon: point[:lon],
          priority: point[:priority]
        }.merge(structured).merge(working_hours: summary)

        base[:store_type] = point[:store_type] if point.key?(:store_type)
        base[:ops_number] = point[:ops_number] if point.key?(:ops_number)
        base[:ops_name] = point[:ops_name] if point.key?(:ops_name)
        base[:is_large_weight_limit] = point[:is_large_weight_limit] if point.key?(:is_large_weight_limit)
        base
      end

      def europost_pickup_points
        DeliveryOptionsService.europost_offices(europost_store_type: europost_store_type_param).map do |office|
          summary = europost_working_hours(office)
          structured = EuropostWorkingHoursFormatter.structured_for_payload(office)

          row = {
            id: office["WarehouseId"].to_s,
            provider: "europost",
            name: office["WarehouseName"],
            city: office["Address7Name"],
            address: europost_address(office),
            phone: EuropostOfficePhone.for_office(office),
            lat: office["Latitude"]&.to_f,
            lon: office["Longitude"]&.to_f,
            priority: false
          }.merge(structured).merge(working_hours: summary)

          row[:store_type] = office["store_type"] if office.key?("store_type")
          row[:ops_number] = office["ops_number"] if office.key?("ops_number")
          row[:ops_name] = office["ops_name"] if office.key?("ops_name")
          row[:is_large_weight_limit] = office["is_large_weight_limit"] if office.key?("is_large_weight_limit")
          row
        end
      end

      def filter_pickup_points_by_city(points, city)
        query = city.to_s.strip
        return points if query.blank?

        downcased_query = query.downcase
        points.select { |point| point[:city].to_s.downcase.include?(downcased_query) }
      end

      def filter_pickup_points_by_query(points, query)
        downcased_query = query.to_s.downcase
        points.select do |point|
          [point[:name], point[:city], point[:address]]
            .any? { |value| value.to_s.downcase.include?(downcased_query) }
        end
      end

      def cart_for_delivery_options
        return cart_from_items if params[:cart_token].blank? && params[:items].present?

        cart, = CartTokenResolver.call(request: request, params: { cart_token: params[:cart_token] })
        cart
      end

      def cart_from_items
        items = Array(params[:items])
        skus = items.map { |i| i[:sku] || i['sku'] }.compact
        products = Product.where(sku: skus).index_by(&:sku)

        virtual_item = Struct.new(:product, :quantity)
        virtual_items = items.filter_map do |entry|
          sku = (entry[:sku] || entry['sku']).to_s
          quantity = (entry[:quantity] || entry['quantity']).to_i
          product = products[sku]
          next if product.nil? || quantity <= 0

          virtual_item.new(product, quantity)
        end

        Struct.new(:cart_items).new(virtual_items)
      end

      def render_filtered_europost_offices_for_cart_id
        cart = Cart.find_by(id: params[:cart_id])
        unless cart
          render json: { error: "Корзина не найдена" }, status: :unprocessable_entity
          return
        end

        render_filtered_europost_offices_for_cart(cart)
      end

      def render_filtered_europost_offices_for_request_context
        cart = cart_for_delivery_options
        render_filtered_europost_offices_for_cart(cart)
      end

      def render_filtered_europost_offices_for_order_id
        order = Order.find_by(id: params[:order_id], checkout_draft: true)
        unless order
          render json: { error: "Черновик заказа не найден" }, status: :unprocessable_entity
          return
        end

        cart_like = CartPricingService.order_as_cart(order)
        render_filtered_europost_offices_for_cart(cart_like)
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

      def europost_offices_cart_context?
        params[:cart_token].present? || params[:items].present?
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

module Api
  module V1
    class DeliveryController < ApplicationController
      include CartResponseFormatter

      # GET /api/v1/delivery/types
      # Returns delivery types + available pickup points.
      def types
        render json: {
          types: [
            { key: DeliveryTypeNormalizer::EUROPOST_PICKUP, name: 'Пункт выдачи Европочты' },
            { key: DeliveryTypeNormalizer::COURIER, name: 'Курьер' },
            { key: DeliveryTypeNormalizer::IKEYA_DELIVERY, name: 'Доставка IKEYA' }
          ],
          providers: PickupPoint::PROVIDERS
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

        poland_delivery_pln = PolandDeliveryService.calculate(weight_kg)
        belarus_delivery_pln = BelarusDeliveryService.calculate(weight_kg)
        
        total_delivery_pln = poland_delivery_pln + belarus_delivery_pln
        total_delivery_byn = (total_delivery_pln * pln_rate_with_buffer).round(2)
        poland_delivery_byn = (poland_delivery_pln * pln_rate_with_buffer).round(2)
        belarus_delivery_byn = (belarus_delivery_pln * pln_rate_with_buffer).round(2)

        delivery_price_byn =
          if normalized_delivery_type == DeliveryTypeNormalizer::IKEYA_DELIVERY
            0.0
          else
            poland_delivery_byn
          end
        delivery_to_belarus_price_byn = belarus_delivery_byn
        total_delivery_price_byn = (delivery_price_byn + delivery_to_belarus_price_byn).round(2)

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
            base_cost_byn: sprintf('%.2f', total_delivery_byn),
            poland_delivery_byn: sprintf('%.2f', poland_delivery_byn),
            belarus_delivery_byn: sprintf('%.2f', belarus_delivery_byn),
            free_delivery_threshold_byn: sprintf('%.2f', rules[:rules][:free_delivery_threshold_byn]),
            free_delivery_eligible: subtotal_byn >= rules[:rules][:free_delivery_threshold_byn],
            free_delivery_missing_byn: sprintf('%.2f', rules[:flags][:free_delivery_missing_byn]),
            delivery_type: delivery_type,
            normalized_delivery_type: normalized_delivery_type,
            available: selected_method[:available],
            delivery_date: eta[:delivery_date],
            storage_until: eta[:storage_until],
            delivery_price_byn: sprintf('%.2f', delivery_price_byn),
            delivery_to_belarus_price_byn: sprintf('%.2f', delivery_to_belarus_price_byn),
            total_delivery_price_byn: sprintf('%.2f', total_delivery_price_byn),
            display: {
              title: "Доставка",
              subtitle: normalized_delivery_type,
              total_delivery_price_byn: sprintf('%.2f', total_delivery_price_byn)
            }
          },
          pickup_point: pp_eval
        }
      end

      # GET /api/v1/delivery/pickup_points
      def pickup_points
        points = PickupPoint.active.ordered
        render json: { pickup_points: points.map { |p| pickup_point_payload(p) } }
      end

      # ... остальное без изменений ...
      def pickup_points_search
        q = params[:query].to_s.strip
        points = PickupPoint.active.ordered
        if q.present?
          points = points.where('name ILIKE ? OR city ILIKE ? OR address ILIKE ?', "%#{q}%", "%#{q}%", "%#{q}%")
        end
        render json: { pickup_points: points.limit(50).map { |p| pickup_point_payload(p) } }
      end

      def europost_offices
        if params[:cart_id].present?
          return render_filtered_europost_offices_for_cart
        end

        offices = EuropostApiService.offices_out
        render json: {
          offices: offices.map { |office| europost_office_payload(office) }
        }
      end

      private

      def europost_office_payload(office)
        external_id = office["WarehouseId"].to_s

        {
          id: external_id,
          external_id: external_id,
          name: office["WarehouseName"],
          city: office["Address7Name"],
          address: europost_address(office),
          phone: nil,
          working_hours: europost_working_hours(office),
          lat: office["Latitude"],
          lon: office["Longitude"],
          lng: office["Longitude"],
          provider: "europost",
          max_weight_kg: DeliveryOptionsService.europost_office_weight_limit_kg(office)
        }
      end

      def europost_address(office)
        [office['Address5Name'], office['Address4Name'], office['Address3Name']]
          .map { |value| value.to_s.strip }
          .reject(&:blank?)
          .join(', ')
          .presence
      end

      def europost_working_hours(office)
        info_texts = [office['Info1'], office['Info2'], office['Info3']]
          .map { |value| value.to_s.strip }
          .reject(&:blank?)

        info_texts.find { |text| text.match?(/режим\s*работы|hours|time/i) } || info_texts.first || ""
      end

      def calculation_basis
        if params[:cart_token].present?
          cart, = CartTokenResolver.call(request: request, params: { cart_token: params[:cart_token] })
          pricing = CartPricingService.call(cart: cart)
          subtotal = pricing[:totals][:items_total_byn].to_f
          weight = cart.cart_items.joins(:product).sum('products.weight * cart_items.quantity').to_f
          volume = cart.cart_items.joins(:product).sum('products.package_volume * cart_items.quantity').to_f
          [weight, volume, subtotal]
        else
          items = Array(params[:items])
          skus = items.map { |i| i[:sku] || i['sku'] }.compact
          products = Product.with_available_stock.where(sku: skus).index_by(&:sku)
          
          # Согласованно с CartPricingService: товары с K + delivery_cost + WC_BY по весу строки
          total_pln = 0.0
          total_weight = 0.0
          
          items.each do |i|
            sku = (i[:sku] || i['sku']).to_s
            qty = (i[:quantity] || i['quantity']).to_i
            p = products[sku]
            next unless p && qty.positive?
            
            pln_price = p.price.to_f
            w = p.weight.to_f
            line_weight = w * qty
            markup_k = PriceCalculationService.compute_k(pln_price)
            line_goods = pln_price * (1 + markup_k) * qty
            line_delivery = p.delivery_cost.to_f * qty
            line_wc = BelarusDeliveryService.calculate(line_weight)
            total_pln += line_goods + line_delivery + line_wc
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

      def pickup_point_payload(p)
        {
          id: p.id,
          provider: p.provider,
          name: p.name,
          city: p.city,
          address: p.address,
          phone: p.phone,
          working_hours: p.working_hours,
          lat: p.lat&.to_f,
          lon: p.lon&.to_f,
          priority: p.priority
        }
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

      def render_filtered_europost_offices_for_cart
        cart = Cart.find_by(id: params[:cart_id])
        unless cart
          render json: { error: "Корзина не найдена" }, status: :unprocessable_entity
          return
        end

        options = DeliveryOptionsService.call(cart)
        cart_vgh = options[:cart_vgh]
        parcels = options[:parcels]
        eta = DeliveryEtaService.call(order_date: Date.current, with_storage: true)
        pricing = delivery_pricing_for_weight(cart_vgh[:weight_kg].to_f)

        api_offices = DeliveryOptionsService.europost_offices
        offices = api_offices.filter_map do |office|
          available_for_cart = cart_vgh[:eligible_for_europost] &&
                               DeliveryOptionsService.europost_office_supports_parcels?(office: office, parcels: parcels)
          next unless available_for_cart

          europost_office_payload(office).merge(
            available_for_cart: true,
            delivery_date: eta[:delivery_date],
            storage_until: eta[:storage_until],
            delivery_price_byn: sprintf("%.2f", pricing[:delivery_price_byn]),
            delivery_to_belarus_price_byn: sprintf("%.2f", pricing[:delivery_to_belarus_price_byn]),
            total_delivery_price_byn: sprintf("%.2f", pricing[:total_delivery_price_byn])
          )
        end

        render json: { offices: offices }
      end

      def delivery_pricing_for_weight(weight_kg)
        pln_rate = ExchangeRate.fetch_or_create("PLN")&.rate_per_unit || 0
        buffer = PriceCalculationService.exchange_rate_buffer
        pln_rate_with_buffer = pln_rate * buffer

        poland_delivery_pln = PolandDeliveryService.calculate(weight_kg)
        belarus_delivery_pln = BelarusDeliveryService.calculate(weight_kg)

        delivery_price_byn = (poland_delivery_pln * pln_rate_with_buffer).round(2)
        delivery_to_belarus_price_byn = (belarus_delivery_pln * pln_rate_with_buffer).round(2)

        {
          delivery_price_byn: delivery_price_byn,
          delivery_to_belarus_price_byn: delivery_to_belarus_price_byn,
          total_delivery_price_byn: (delivery_price_byn + delivery_to_belarus_price_byn).round(2)
        }
      end
    end
  end
end

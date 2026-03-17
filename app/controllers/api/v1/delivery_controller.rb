module Api
  module V1
    class DeliveryController < ApplicationController
      include CartResponseFormatter

      # GET /api/v1/delivery/types
      # Returns delivery types + available pickup points.
      def types
        render json: {
          types: [
            { key: 'pickup', name: 'Пункт выдачи' },
            { key: 'courier', name: 'Курьер' }
          ],
          providers: PickupPoint::PROVIDERS
        }
      end

      # POST /api/v1/delivery/calculate
      # Either provide cart_token or items.
      def calculate
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

        rules = CartRulesService.call(subtotal_new_byn: subtotal_byn)

        pp = params[:pickup_point_id].present? ? PickupPoint.find_by(id: params[:pickup_point_id]) : nil
        pp_eval = pp ? pickup_point_eligibility(pp, weight_kg, 0) : nil

        render json: {
          basis: {
            total_weight_kg: weight_kg,
            subtotal_byn: sprintf('%.2f', subtotal_byn)
          },
          delivery: {
            type: params[:delivery_type],
            base_cost_byn: sprintf('%.2f', total_delivery_byn),
            poland_delivery_byn: sprintf('%.2f', (poland_delivery_pln * pln_rate_with_buffer).round(2)),
            belarus_delivery_byn: sprintf('%.2f', (belarus_delivery_pln * pln_rate_with_buffer).round(2)),
            free_delivery_threshold_byn: sprintf('%.2f', rules[:rules][:free_delivery_threshold_byn]),
            free_delivery_eligible: subtotal_byn >= rules[:rules][:free_delivery_threshold_byn],
            free_delivery_missing_byn: sprintf('%.2f', rules[:flags][:free_delivery_missing_byn])
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
        offices = EuropostApiService.offices_out
        render json: { 
          offices: offices.map { |o|
            {
              external_id: o['WarehouseId'],
              name: o['WarehouseName'],
              city: o['Address7Name'],
              address: o['Info1'].presence || "#{o['Address5Name']}, #{o['Address4Name']} #{o['Address3Name']}",
              phone: nil,
              working_hours: o['Info1'],
              lat: o['Latitude'],
              lon: o['Longitude'],
              provider: 'europost'
            }
          }
        }
      end

      def autolight_offices
        res = AutolightApiService.get_post_offices_list
        offices = res['result'] || []
        
        render json: {
          offices: offices.map { |o|
            {
              external_id: o['code'],
              name: o['name'],
              city: o['cityName'],
              address: o['address'],
              phone: o['contacts'],
              working_hours: o['workTime'],
              lat: o['coordLat'],
              lon: o['coordLong'],
              provider: 'autolight'
            }
          }
        }
      end

      private

      def calculation_basis
        if params[:cart_token].present?
          cart, = CartTokenResolver.call(request: request, params: { cart_token: params[:cart_token] })
          pricing = CartPricingService.call(cart: cart)
          subtotal = pricing[:totals][:total_byn].to_f
          weight = cart.cart_items.joins(:product).sum('products.weight * cart_items.quantity').to_f
          volume = cart.cart_items.joins(:product).sum('products.package_volume * cart_items.quantity').to_f
          [weight, volume, subtotal]
        else
          items = Array(params[:items])
          skus = items.map { |i| i[:sku] || i['sku'] }.compact
          products = Product.where(sku: skus).index_by(&:sku)
          
          # Для расчета без корзины нам нужно знать цены и веса
          total_pln_with_markup = 0.0
          total_weight = 0.0
          
          items.each do |i|
            sku = (i[:sku] || i['sku']).to_s
            qty = (i[:quantity] || i['quantity']).to_i
            p = products[sku]
            next unless p && qty.positive?
            
            pln_price = p.price.to_f
            markup_k = PriceCalculationService.compute_k(pln_price)
            total_pln_with_markup += pln_price * (1 + markup_k) * qty
            total_weight += p.weight.to_f * qty
          end
          
          pln_rate = ExchangeRate.fetch_or_create('PLN')&.rate_per_unit || 0
          buffer = PriceCalculationService.exchange_rate_buffer
          subtotal_byn = (total_pln_with_markup * pln_rate * buffer).round(2)
          
          [total_weight, 0, subtotal_byn]
        end
      end

      def pickup_point_eligibility(pp, weight_kg, volume_m3)
        eligible = true
        reasons = []

        if pp.max_weight_kg.present? && weight_kg.to_f > pp.max_weight_kg.to_f
          eligible = false
          reasons << 'max_weight_exceeded'
        end
        if pp.max_volume_m3.present? && volume_m3.to_f > pp.max_volume_m3.to_f
          eligible = false
          reasons << 'max_volume_exceeded'
        end

        payload = pickup_point_payload(pp)
        payload[:eligible] = eligible
        payload[:reasons] = reasons
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
    end
  end
end

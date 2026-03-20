class DeliveryTrackingService
  def self.call(order)
    return nil unless order.track_number.present?

    info = case order.delivery_type
           when 'europost'
             EuropostTracker.track(order.track_number)
           when 'autolight'
             AutolightTracker.track(order.track_number)
           else
             { status: 'Информация об отслеживании недоступна', provider: order.delivery_type }
           end

    order.update_columns(tracking_info: info) if info
    info
  end
end

class EuropostTracker
  def self.track(track_number)
    events = EuropostApiService.postal_tracking(number: track_number)
    return nil if events.empty?

    # По доке последние события обычно в конце или имеют статус
    last_event = events.last

    {
      status: last_event['Out_StatusName'] || last_event['InfoTrack'] || 'В пути',
      last_update: last_event['Out_DateStatus'] || Time.current.strftime('%d.%m.%Y %H:%M'),
      provider: 'Европочта',
      tracking_url: "https://evropochta.by/tracking/?number=#{track_number}",
      history: events
    }
  end
end

class AutolightTracker
  def self.track(track_number)
    res = AutolightApiService.get_tracking(order_number: track_number)
    
    if res['resultCode'] == 0 && res['result'].is_a?(Hash)
      details = res['result']['orderDetails'] || {}
      track = res['result']['track'] || []
      last_event = track.last || {}

      {
        status: details['status'] || last_event['status'] || 'В пути',
        last_update: last_event['date'] || details['deliveryDate'] || Time.current.strftime('%d.%m.%Y %H:%M'),
        provider: 'Автолайт',
        tracking_url: "http://api.autolight.by/v1/getTracking/?orderNumber=#{track_number}",
        history: track
      }
    else
      {
        status: 'Информация об отслеживании недоступна',
        last_update: Time.current.strftime('%d.%m.%Y %H:%M'),
        provider: 'Автолайт',
        tracking_url: "https://autolight.by/services/it-services/tracking/?track=#{track_number}"
      }
    end
  end
end

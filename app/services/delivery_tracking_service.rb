class DeliveryTrackingService
  def self.call(order)
    return nil unless order.track_number.present?

    normalized_delivery_type = DeliveryTypeNormalizer.normalize(order.delivery_type)

    info = case normalized_delivery_type
           when 'europost'
             EuropostTracker.track(order.track_number)
           when 'europost_pickup'
             EuropostTracker.track(order.track_number)
           else
             { status: 'Информация об отслеживании недоступна', provider: normalized_delivery_type }
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

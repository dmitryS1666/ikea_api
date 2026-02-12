class DeliveryTrackingService
  def self.call(order)
    return nil unless order.track_number.present?

    case order.delivery_type
    when 'europost'
      EuropostTracker.track(order.track_number)
    when 'autolight'
      AutolightTracker.track(order.track_number)
    else
      { status: 'Информация об отслеживании недоступна', provider: order.delivery_type }
    end
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
    # Stub: Autolight integration usually via https://autolight.by/services/it-services/integration/
    {
      status: 'Прибыло в пункт выдачи (заглушка)',
      last_update: Time.current.strftime('%d.%m.%Y %H:%M'),
      provider: 'Автолайт',
      tracking_url: "https://autolight.by/services/it-services/tracking/?track=#{track_number}"
    }
  end
end

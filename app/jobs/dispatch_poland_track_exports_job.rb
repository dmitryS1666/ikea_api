# frozen_string_literal: true

class DispatchPolandTrackExportsJob < ApplicationJob
  queue_as :default

  def perform
    return unless PolandTrackExport.enabled?

    # A dead process may have sent the POST. Never retry its request automatically.
    PolandTrackExport.where(state: "sending").where("last_attempt_at < ?", 10.minutes.ago).find_each do |export|
      export.with_lock do
        next unless export.state == "sending" && export.last_attempt_at < 10.minutes.ago
        export.update!(state: "uncertain", last_error: "Worker interrupted; reconcile before retry")
      end
    end
    # Recover exports blocked only by missing historical PLN/URL/weight when catalog can fill them.
    PolandTrackExport.requeue_healable_blocked!
    PolandTrackExport.due.find_each { |export| PolandTrackExportJob.perform_later(export.id) }
  end
end

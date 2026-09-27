# frozen_string_literal: true

class PolandTrackExportJob < ApplicationJob
  queue_as :default

  def perform(export_id)
    export = PolandTrackExport.find_by(id: export_id)
    PolandTracks::ExportService.call(export) if export
  end
end

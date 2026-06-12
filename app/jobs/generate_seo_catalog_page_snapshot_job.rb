class GenerateSeoCatalogPageSnapshotJob < ApplicationJob
  queue_as :default

  def perform(seo_catalog_page_id)
    page = SeoCatalogPage.find_by(id: seo_catalog_page_id)
    return unless page

    SeoCatalogPages::GenerateSnapshotService.call(page)
  end
end

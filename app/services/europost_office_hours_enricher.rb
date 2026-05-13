# frozen_string_literal: true

# Merges working-hours metadata from GET /api/external/stores into Postal.OfficesOut rows (matched by WarehouseId == store id).
class EuropostOfficeHoursEnricher
  STORE_KEYS = %w[
    schedules break_hours working_hours break breaks
    is_large_weight_limit ops_number ops_name
  ].freeze

  def self.enrich(offices, type: nil)
    return offices unless offices.is_a?(Array)
    return offices if offices.empty?

    token = ENV["EUROPOST_API_TOKEN"].to_s.strip
    return offices if token.blank?

    stores = fetch_stores_index(type: type)
    return offices if stores.empty?

    offices.map { |office| merge_store(office, stores) }
  rescue StandardError => e
    Rails.logger.error("[EUROPOST] external stores enrich failed #{e.class}: #{e.message}")
    offices
  end

  def self.merge_store(office, stores_by_id)
    oid = office["WarehouseId"] || office[:WarehouseId]
    store = stores_by_id[oid.to_s]
    return office unless store.is_a?(Hash)

    merged = office.is_a?(Hash) ? office.dup : office.to_h
    STORE_KEYS.each do |key|
      next unless store.key?(key) || store.key?(key.to_sym)

      val = store[key] || store[key.to_sym]
      merged[key] = val unless val.nil?
    end

    stype = store["type"] || store[:type]
    merged["store_type"] = stype unless stype.nil?

    merged
  end
  private_class_method :merge_store

  def self.fetch_stores_index(type: nil)
    list = EuropostApiService.external_stores(type: type)
    return {} unless list.is_a?(Array)

    list.each_with_object({}) do |row, acc|
      next unless row.is_a?(Hash)

      rid = row["id"] || row[:id]
      acc[rid.to_s] = row if rid.present?
    end
  end
  private_class_method :fetch_stores_index
end

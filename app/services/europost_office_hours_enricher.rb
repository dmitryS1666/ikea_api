# frozen_string_literal: true

# Merges working-hours metadata from GET /api/external/stores into Postal.OfficesOut rows.
# Match order: WarehouseId == store.id, then WarehouseId == store.ops_number (IDs differ across Europost APIs).
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

    by_id, by_ops = fetch_stores_indexes(type: type)
    return offices if by_id.empty? && by_ops.empty?

    offices.map { |office| merge_store(office, by_id, by_ops) }
  rescue StandardError => e
    Rails.logger.error("[EUROPOST] external stores enrich failed #{e.class}: #{e.message}")
    offices
  end

  def self.merge_store(office, by_id, by_ops)
    oid = (office["WarehouseId"] || office[:WarehouseId]).to_s.presence
    store = oid.present? ? lookup_store(oid, by_id, by_ops) : nil
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

  def self.fetch_stores_indexes(type: nil)
    list = EuropostApiService.external_stores_for_merge(type: type)
    return [{}, {}] unless list.is_a?(Array)

    by_id = {}
    by_ops = {}
    list.each do |row|
      next unless row.is_a?(Hash)

      rid = row["id"] || row[:id]
      if rid.present?
        id_lookup_variants(rid.to_s).each { |k| by_id[k] ||= row }
      end

      on = row["ops_number"] || row[:ops_number]
      next if on.blank?

      id_lookup_variants(on.to_s).each { |k| by_ops[k] ||= row }
    end
    [by_id, by_ops]
  end
  private_class_method :fetch_stores_indexes

  def self.lookup_store(oid, by_id, by_ops)
    id_lookup_variants(oid).each do |k|
      found = by_id[k] || by_ops[k]
      return found if found
    end
    nil
  end
  private_class_method :lookup_store

  def self.id_lookup_variants(raw)
    s = raw.to_s.strip
    return [] if s.blank?

    stripped = s.sub(/\A0+/, "")
    stripped = s if stripped.empty?

    [s, stripped].uniq
  end
  private_class_method :id_lookup_variants
end

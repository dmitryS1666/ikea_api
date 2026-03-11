module CategoryCleanup
  class ImportRules < Base
    def call
      decisions = DecisionsReader.new.call

      CategoryCleanupRule.transaction do
        CategoryCleanupRule.delete_all

        decisions.each do |decision|
          CategoryCleanupRule.create!(
            source_row_no: decision.source_row_no,
            source_ikea_id: decision.source_ikea_id,
            source_url: decision.source_url,
            raw_status: decision.raw_status,
            action: decision.action,
            target_row_no: decision.target_row_no,
            target_ikea_id: decision.target_ikea_id,
            resolution_status: 'pending'
          )
        end
      end
    end
  end
end

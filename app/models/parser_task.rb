class ParserTask < ApplicationRecord
  TASK_TYPES = %w[recover_broken_product_images update_all_product_images update_product_variants categories products bestsellers popular_categories category_images product_images extended_attributes currency_rates category_filters category_filters_one extended_attrs_import fix_missing_images extended_attributes_by_skus import_products_by_skus recover_missing_images recover_missing_weights refresh_category_lt refresh_product_lt pl_prices_stock].freeze
  STATUSES = %w[pending running completed failed].freeze

  validates :task_type, presence: true, inclusion: { in: TASK_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
  scope :running, -> { where(status: 'running') }
  scope :completed, -> { where(status: 'completed') }
  scope :failed, -> { where(status: 'failed') }
  scope :by_type, ->(type) { where(task_type: type) }

  def duration
    return nil unless started_at && completed_at
    completed_at - started_at
  end

  def mark_as_running!
    update!(
      status: 'running',
      started_at: Time.current,
      error_message: nil
    )
  end

  def mark_as_completed!(stats = {})
    self.reload
    update!(
      status: 'completed',
      completed_at: Time.current,
      processed: stats[:processed] || self.processed || 0,
      created: stats[:created] || self.created || 0,
      updated: stats[:updated] || self.updated || 0,
      error_count: stats[:errors] || self.error_count || 0
    )
  end

  def mark_as_failed!(error_message)
    update!(
      status: 'failed',
      completed_at: Time.current,
      error_message: error_message
    )
  end

  def increment_processed!
    self.class.update_counters(id, processed: 1)
    self.processed = (self.processed || 0) + 1
  end

  def increment_created!
    self.class.update_counters(id, created: 1)
    self.created = (self.created || 0) + 1
  end

  def increment_updated!
    self.class.update_counters(id, updated: 1)
    self.updated = (self.updated || 0) + 1
  end

  def increment_errors!
    self.class.update_counters(id, error_count: 1)
    self.error_count = (self.error_count || 0) + 1
  end

  def reset_task!
    update!(
      processed: 0,
      created: 0,
      updated: 0,
      error_count: 0,
      payload: (payload || {}).merge('last_id' => nil),
      started_at: nil,
      completed_at: nil,
      error_message: nil,
      status: 'pending'
    )
  end

  def update_payload!(updates = {})
    self.payload = (payload || {}).merge(updates)
    update_column(:payload, payload)
  end
end



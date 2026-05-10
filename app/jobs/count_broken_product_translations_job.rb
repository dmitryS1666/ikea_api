# frozen_string_literal: true

class CountBrokenProductTranslationsJob < ApplicationJob
  queue_as :parser

  PL_MARKERS = %w[
    materiał materiały wymiary waga szerokość wysokość głębokość opakowanie
    sztuk zestaw elementów instrukcja montażu pranie prać
    pokrycie obicia nóżki podłokietnik zawiera skład
  ].freeze

  def perform(limit: nil, task_id: nil)
    task = task_id ? ParserTask.find(task_id) : create_parser_task("count_broken_product_translations", limit: limit)
    task.update!(processed: 0, updated: 0, error_count: 0) if task.status == "pending"
    task.mark_as_running!

    notify_started("count_broken_product_translations", limit: limit)
    started_at = Time.current

    suspect = 0
    total = 0
    sample_skus = []

    scope = Product.order(:id)
    scope = scope.limit(limit.to_i) if limit.present? && limit.to_i.positive?

    scope.find_each(batch_size: 200) do |product|
      check_task_not_stopped!(task)

      payload = ProductSerializer.customer_full_attributes_payload(product)
      texts = deep_strings(payload).uniq
      is_suspect = texts.any? { |text| likely_polish_not_russian?(text) }

      if is_suspect
        suspect += 1
        sample_skus << product.sku if sample_skus.size < 20
      end

      total += 1
      task.increment_processed!
    end

    stats = {
      processed: total,
      updated: suspect,
      errors: 0,
      duration: Time.current - started_at
    }

    task.update_payload!(
      "metric" => "suspected_polish_in_api_full_attributes_payload",
      "broken_count" => suspect,
      "total_checked" => total,
      "percent" => total.zero? ? 0.0 : ((suspect.to_f * 100.0 / total).round(2)),
      "sample_skus" => sample_skus
    )
    task.mark_as_completed!(stats)
    notify_completed("count_broken_product_translations", stats)
  rescue StandardError => e
    return if e.message == "Task was stopped manually"

    task&.mark_as_failed!(e.message)
    notify_error("count_broken_product_translations", e)
    raise
  end

  private

  def deep_strings(obj, acc = [])
    case obj
    when String
      stripped = obj.strip
      acc << stripped if stripped.length >= 12
    when Hash
      obj.each_value { |v| deep_strings(v, acc) }
    when Array
      obj.each { |v| deep_strings(v, acc) }
    end
    acc
  end

  def likely_polish_not_russian?(text)
    return false if text.blank? || text.length < 12

    cyr = text.scan(/[а-яА-ЯёЁ]/).size
    lat = text.scan(/[A-Za-zÀ-ÿ]/).size
    return false if lat < 8
    return false if cyr >= 12 || (lat.positive? && (cyr.to_f / (cyr + lat)) > 0.25)
    return true if text.match?(/[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]/)

    low = text.downcase
    PL_MARKERS.any? { |word| low.include?(word) }
  end
end


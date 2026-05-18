# frozen_string_literal: true

# Собирает f-series в available_filters из товаров категории и поддерева,
# опционально пропагирует список в дочерние категории и ставит переиндексацию f-series.
#
#   RebuildCategoryFseriesFiltersJob.perform_later("hs001")
#   RebuildCategoryFseriesFiltersJob.perform_later("hs001", task_id: id, reindex: true, propagate_to_descendants: true)
class RebuildCategoryFseriesFiltersJob < ApplicationJob
  queue_as :parser

  def perform(ikea_id = nil, task_id: nil, reindex: true, propagate_to_descendants: true)
    task = ParserTask.find_by(id: task_id) if task_id.present?
    task&.mark_as_running!

    stats = { processed: 0, updated: 0, errors: 0, series_count: 0 }

    if ikea_id.present?
      run_single(
        ikea_id,
        task: task,
        reindex: reindex,
        propagate_to_descendants: propagate_to_descendants,
        stats: stats
      )
    else
      Category.not_deleted.find_each do |category|
        stats[:processed] += 1
        begin
          result = Categories::RebuildFseriesAvailableFiltersService.new(
            category,
            propagate_to_descendants: propagate_to_descendants
          ).call
          stats[:series_count] += result.series_count
          if result.changed
            stats[:updated] += result.categories_updated
            enqueue_reindex_for_tree(category, reindex: reindex)
          end
        rescue StandardError => e
          stats[:errors] += 1
          Rails.logger.error(
            "RebuildCategoryFseriesFiltersJob category=#{category.ikea_id} #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}"
          )
        end
      end

      task&.mark_as_completed!(
        processed: stats[:processed],
        updated: stats[:updated],
        errors: stats[:errors]
      )
    end
  rescue StandardError => e
    Rails.logger.error("RebuildCategoryFseriesFiltersJob: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}")
    task&.mark_as_failed!(e.message)
    raise e if task_id.blank?
  end

  private

  def run_single(ikea_id, task:, reindex:, propagate_to_descendants:, stats:)
    category = Category.find_by(ikea_id: ikea_id.to_s)
    unless category
      msg = "Категория не найдена: #{ikea_id}"
      Rails.logger.error("RebuildCategoryFseriesFiltersJob: #{msg}")
      task&.mark_as_failed!(msg)
      return
    end

    stats[:processed] = 1
    result = Categories::RebuildFseriesAvailableFiltersService.new(
      category,
      propagate_to_descendants: propagate_to_descendants
    ).call

    stats[:series_count] = result.series_count
    stats[:updated] = result.categories_updated if result.changed

    enqueue_reindex_for_tree(category, reindex: reindex) if reindex && result.changed

    task&.mark_as_completed!(
      processed: stats[:processed],
      updated: stats[:updated],
      errors: stats[:errors]
    )
  rescue StandardError => e
    stats[:errors] = 1
    raise
  end

  def enqueue_reindex_for_tree(category, reindex:)
    return unless reindex

    category.self_and_descendant_ikea_ids.each do |category_id|
      ReindexCategoryFiltersJob.perform_later(category_id, parameters: %w[f-series])
    end
  end
end

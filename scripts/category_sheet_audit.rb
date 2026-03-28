# frozen_string_literal: true

require "csv"
require "json"
require "open-uri"
require "uri"
require "fileutils"
require "set"

module CategorySheetAudit
  class Error < StandardError; end

  class Runner
    DEFAULT_SHEET_URL = "https://docs.google.com/spreadsheets/d/1S1Z3buY4aDNxQwqAP2jbqCIP5iiCjtPLz6zWkXD6bj0/edit?hl=ru&gid=0"
    DEFAULT_CACHE_KEYS = %w[
      categories_tree_v1
      categories_map_json
    ].freeze

    def initialize(
      sheet_url: ENV.fetch("SHEET_URL", DEFAULT_SHEET_URL),
      out_dir: ENV.fetch("OUT_DIR", Rails.root.join("tmp", "category_sheet_audit").to_s),
      category_scope: ENV.fetch("CATEGORY_SCOPE", "not_deleted"),
      apply_changes: env_true?("APPLY_CHANGES"),
      clear_rails_cache: env_true?("CLEAR_RAILS_CACHE"),
      clear_all_rails_cache: env_true?("CLEAR_ALL_RAILS_CACHE")
    )
      @sheet_url = sheet_url
      @out_dir = out_dir
      @category_scope = category_scope
      @apply_changes = apply_changes
      @clear_rails_cache = clear_rails_cache
      @clear_all_rails_cache = clear_all_rails_cache
    end

    def call
      FileUtils.mkdir_p(@out_dir)

      rows = download_sheet_rows
      entries = build_entries(rows)
      raise Error, "В таблице не найдено ни одной валидной строки с заполненными A-D" if entries.empty?

      rename_map = entries.each_with_object({}) do |entry, memo|
        memo[entry[:current_path]] = entry[:expected_name]
      end

      entries.each do |entry|
        entry[:expected_full_path] = build_expected_full_path(entry[:current_path], rename_map)
      end

      write_json("sheet_entries.json", entries)

      comparison_report = compare_with_db(entries)
      write_json("comparison_report.json", comparison_report)
      write_text("comparison_report.txt", build_text_report(comparison_report))

      apply_plan = build_apply_plan(entries, comparison_report)
      write_json("apply_plan.json", apply_plan)

      apply_result = if @apply_changes
                       apply_changes!(apply_plan)
                     else
                       {
                         performed: false,
                         mode: "dry_run",
                         message: "Проверочный прогон. Изменения в БД не применялись.",
                         totals: apply_plan[:totals]
                       }
                     end
      write_json("apply_result.json", apply_result)

      cache_report = clear_cache_if_needed(apply_result)
      write_json("cache_clear_report.json", cache_report)

      puts "Done. Files written to: #{@out_dir}"
      puts File.join(@out_dir, "sheet_entries.json")
      puts File.join(@out_dir, "comparison_report.json")
      puts File.join(@out_dir, "comparison_report.txt")
      puts File.join(@out_dir, "apply_plan.json")
      puts File.join(@out_dir, "apply_result.json")
      puts File.join(@out_dir, "cache_clear_report.json")
    end

    private

    def env_true?(key)
      %w[1 true yes y on].include?(ENV.fetch(key, "").to_s.strip.downcase)
    end

    def download_sheet_rows
      csv_url = google_sheet_csv_url(@sheet_url)
    
      content = URI.open(
        csv_url,
        read_timeout: 60,
        open_timeout: 30,
        "User-Agent" => "Ruby/#{RUBY_VERSION}"
      ).read
    
      content = normalize_csv_content(content)
    
      CSV.parse(content, headers: false, liberal_parsing: true)
    rescue OpenURI::HTTPError => e
      raise Error, "Не удалось скачать CSV из Google Sheet: #{e.message} (URL: #{csv_url})"
    rescue StandardError => e
      raise Error, "Ошибка чтения Google Sheet: #{e.class} - #{e.message}"
    end
    
    def normalize_csv_content(content)
      string = content.dup
    
      # если пришло в binary/ascii-8bit — считаем что это UTF-8 CSV
      string.force_encoding(Encoding::UTF_8)
    
      # убираем BOM в начале файла
      string.sub!(/\A\uFEFF/, "")
      string.sub!(/\A\xEF\xBB\xBF/, "")
    
      # подчищаем битые символы, если встретятся
      string.encode!(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    
      string
    end

    def google_sheet_csv_url(url)
      uri = URI.parse(url)
      match = uri.path.match(%r{/spreadsheets/d/([^/]+)})
      raise Error, "Не удалось извлечь spreadsheet id из URL: #{url}" unless match

      spreadsheet_id = match[1]
      query = URI.decode_www_form(String(uri.query)).to_h
      gid = query["gid"].presence || "0"

      "https://docs.google.com/spreadsheets/d/#{spreadsheet_id}/export?format=csv&gid=#{gid}"
    end

    def build_entries(rows)
      entries = []
    
      # Храним текущий контекст по колонкам A-D
      context = [nil, nil, nil, nil]
    
      rows.each_with_index do |row, index|
        cells = Array(row).map { |value| cleanup(value) }
        a, b, c, d, _e, f = cells.values_at(0, 1, 2, 3, 4, 5)
    
        raw_levels = [a, b, c, d]
    
        # Если строка вообще не содержит A-D, пропускаем
        next if raw_levels.compact_blank.empty?
    
        # Обновляем контекст и сбрасываем дочерние уровни,
        # когда встретили новое значение на более высоком уровне
        raw_levels.each_with_index do |value, level|
          next if value.blank?
    
          context[level] = value
          ((level + 1)...context.size).each { |i| context[i] = nil }
        end
    
        current_path = context.compact_blank
        next if current_path.empty?
    
        current_name = current_path.last
        expected_name = f.presence || current_name
    
        entries << {
          row_number: index + 1,
          level: current_path.size,
          current_path: current_path.dup,
          current_name: current_name,
          expected_name: expected_name,
          expected_path: current_path[0...-1] + [expected_name],
          source: {
            a: a,
            b: b,
            c: c,
            d: d,
            f: f
          }
        }
      end
    
      entries
    end

    def build_expected_full_path(current_path, rename_map)
      current_path.each_index.map do |idx|
        prefix = current_path[0..idx]
        rename_map[prefix] || current_path[idx]
      end
    end

    def compare_with_db(entries)
      categories = load_categories
      by_id = categories.index_by { |category| category.ikea_id.to_s }
    
      matched_ids = Set.new
      results = entries.map do |entry|
        candidates = find_candidates(entry, categories, by_id)
      
        case candidates.size
        when 0
          {
            row_number: entry[:row_number],
            status: "not_found",
            current_path: entry[:current_path],
            expected_full_path: entry[:expected_full_path],
            current_name: entry[:current_name],
            expected_name: entry[:expected_name],
            message: "Категория не найдена по пути из таблицы"
          }
        when 1
          category = candidates.first
          matched_ids << category.ikea_id.to_s

          db_path = actual_path_for(category, by_id)
          db_display_name = display_name(category)

          hierarchy_ok = normalized_path(db_path[0...-1]) == normalized_path(entry[:expected_full_path][0...-1])
          display_name_ok = text_equal?(db_display_name, entry[:expected_name])
          translated_name_ok = text_equal?(category.translated_name, entry[:expected_name])

          problems = []
          problems << "hierarchy_mismatch" unless hierarchy_ok
          problems << "display_name_mismatch" unless display_name_ok
          problems << "translated_name_mismatch" unless translated_name_ok

          {
            row_number: entry[:row_number],
            status: problems.empty? ? "ok" : problems.join(","),
            problems: problems,
            current_path: entry[:current_path],
            expected_full_path: entry[:expected_full_path],
            current_name: entry[:current_name],
            expected_name: entry[:expected_name],
            db: {
              ikea_id: category.ikea_id.to_s,
              name: category.name,
              translated_name: category.translated_name,
              display_name: db_display_name,
              parent_ids: Category.normalize_parent_ids(category.parent_ids),
              db_path: db_path,
              current_parent_ikea_id: category.current_parent_ikea_id
            },
            checks: {
              hierarchy_ok: hierarchy_ok,
              display_name_ok: display_name_ok,
              translated_name_ok: translated_name_ok
            },
            suggested_update: build_suggested_update(category, entry, hierarchy_ok, display_name_ok, translated_name_ok)
          }
        else
          {
            row_number: entry[:row_number],
            status: "ambiguous",
            current_path: entry[:current_path],
            expected_full_path: entry[:expected_full_path],
            current_name: entry[:current_name],
            expected_name: entry[:expected_name],
            candidates: candidates.map do |category|
              {
                ikea_id: category.ikea_id.to_s,
                name: category.name,
                translated_name: category.translated_name,
                display_name: display_name(category),
                db_path: actual_path_for(category, by_id)
              }
            end
          }
        end
      end

      {
        generated_at: Time.current.iso8601,
        sheet_url: @sheet_url,
        csv_url: google_sheet_csv_url(@sheet_url),
        category_scope: @category_scope,
        totals: build_totals(results, entries.size),
        results: results,
        matched_ikea_ids: matched_ids.to_a.sort
      }
    end

    def build_apply_plan(entries, comparison_report)
      categories = load_categories
      by_id = categories.index_by { |category| category.ikea_id.to_s }
      results_by_row = comparison_report[:results].index_by { |row| row[:row_number] }

      expected_path_to_ikea_id = {}
      comparison_report[:results].each do |row|
        next unless row[:db].present?

        expected_path_to_ikea_id[normalized_path(row[:expected_full_path])] = row[:db][:ikea_id].to_s
      end

      final_parent_chain_by_ikea_id = {}
      operations = []
      skipped = []

      entries.sort_by { |entry| [entry[:level], entry[:row_number]] }.each do |entry|
        row = results_by_row[entry[:row_number]]

        if row.blank?
          skipped << {
            row_number: entry[:row_number],
            reason: "missing_comparison_row",
            current_path: entry[:current_path]
          }
          next
        end

        unless row[:db].present?
          skipped << {
            row_number: entry[:row_number],
            reason: row[:status],
            current_path: entry[:current_path],
            expected_full_path: entry[:expected_full_path]
          }
          next
        end

        category = by_id[row[:db][:ikea_id].to_s]
        unless category
          skipped << {
            row_number: entry[:row_number],
            reason: "category_not_loaded",
            ikea_id: row.dig(:db, :ikea_id),
            current_path: entry[:current_path]
          }
          next
        end

        desired_parent_path = entry[:expected_full_path][0...-1]
        desired_parent_ikea_id = resolve_parent_ikea_id(
          desired_parent_path,
          expected_path_to_ikea_id,
          by_id
        )

        if desired_parent_path.present? && desired_parent_ikea_id.blank?
          skipped << {
            row_number: entry[:row_number],
            reason: "parent_not_resolved",
            ikea_id: category.ikea_id.to_s,
            desired_parent_path: desired_parent_path
          }
          next
        end

        if desired_parent_ikea_id.to_s == category.ikea_id.to_s
          skipped << {
            row_number: entry[:row_number],
            reason: "self_parent_detected",
            ikea_id: category.ikea_id.to_s,
            desired_parent_path: desired_parent_path
          }
          next
        end

        target_parent_chain =
          if desired_parent_ikea_id.blank?
            []
          else
            parent_chain =
              final_parent_chain_by_ikea_id[desired_parent_ikea_id.to_s] ||
              current_parent_chain_without_self(by_id.fetch(desired_parent_ikea_id.to_s))

            parent_chain + [desired_parent_ikea_id.to_s]
          end

        if target_parent_chain.include?(category.ikea_id.to_s)
          skipped << {
            row_number: entry[:row_number],
            reason: "cycle_detected",
            ikea_id: category.ikea_id.to_s,
            target_parent_chain: target_parent_chain
          }
          next
        end

        final_parent_chain_by_ikea_id[category.ikea_id.to_s] = target_parent_chain

        include_self = parent_ids_include_self?(category)
        target_parent_ids = include_self ? (target_parent_chain + [category.ikea_id.to_s]) : target_parent_chain

        current_parent_ids = Category.normalize_parent_ids(category.parent_ids)
        current_translated_name = category.translated_name
        target_translated_name = entry[:expected_name]

        translated_name_changed = !text_equal?(current_translated_name, target_translated_name)
        parent_ids_changed = normalized_parent_ids_equal?(current_parent_ids, target_parent_ids)

        operations << {
          row_number: entry[:row_number],
          level: entry[:level],
          ikea_id: category.ikea_id.to_s,
          current_path: entry[:current_path],
          expected_full_path: entry[:expected_full_path],
          current: {
            translated_name: current_translated_name,
            display_name: display_name(category),
            parent_ids: current_parent_ids,
            db_path: actual_path_for(category, by_id)
          },
          to: {
            translated_name: target_translated_name,
            parent_ids: target_parent_ids,
            desired_parent_ikea_id: desired_parent_ikea_id
          },
          changes: {
            translated_name: translated_name_changed,
            parent_ids: !parent_ids_changed
          },
          action: (!translated_name_changed && parent_ids_changed) ? "noop" : "update"
        }
      end

      {
        generated_at: Time.current.iso8601,
        apply_mode: @apply_changes ? "apply" : "dry_run",
        totals: {
          rows_in_sheet: entries.size,
          operations_total: operations.size,
          updates: operations.count { |op| op[:action] == "update" },
          noops: operations.count { |op| op[:action] == "noop" },
          skipped: skipped.size
        },
        operations: operations,
        skipped: skipped
      }
    end

    def apply_changes!(apply_plan)
      operations = apply_plan[:operations].select { |op| op[:action] == "update" }
      return {
        performed: true,
        mode: "apply",
        message: "Изменений для применения нет",
        updated: [],
        totals: apply_plan[:totals]
      } if operations.empty?

      updated = []

      ActiveRecord::Base.transaction do
        operations.sort_by { |op| [op[:level], op[:row_number]] }.each do |op|
          category = Category.find(op[:ikea_id])

          category.translated_name = op.dig(:to, :translated_name)
          category.parent_ids = op.dig(:to, :parent_ids)

          category.save!

          updated << {
            row_number: op[:row_number],
            ikea_id: category.ikea_id.to_s,
            translated_name: category.translated_name,
            parent_ids: Category.normalize_parent_ids(category.parent_ids)
          }
        end
      end

      {
        performed: true,
        mode: "apply",
        message: "Изменения успешно применены",
        updated: updated,
        updated_count: updated.size,
        totals: apply_plan[:totals]
      }
    rescue StandardError => e
      {
        performed: false,
        mode: "apply",
        message: "Ошибка применения изменений: #{e.class} - #{e.message}",
        error_class: e.class.name,
        backtrace: Array(e.backtrace).first(20)
      }
    end

    def clear_cache_if_needed(apply_result)
      return {
        performed: false,
        mode: nil,
        cleared_keys: [],
        message: "Cache clear skipped"
      } unless apply_result[:performed]

      return {
        performed: false,
        mode: nil,
        cleared_keys: [],
        message: "Cache clear skipped in dry_run"
      } unless @apply_changes

      return {
        performed: false,
        mode: nil,
        cleared_keys: [],
        message: "Cache clear skipped by flags"
      } unless @clear_rails_cache || @clear_all_rails_cache

      if @clear_all_rails_cache
        Rails.cache.clear
        return {
          performed: true,
          mode: "all",
          cleared_keys: ["*"],
          message: "Полностью очищен Rails.cache"
        }
      end

      cleared_keys = []
      DEFAULT_CACHE_KEYS.each do |key|
        Rails.cache.delete(key)
        cleared_keys << key
      end

      {
        performed: true,
        mode: "selected_keys",
        cleared_keys: cleared_keys,
        message: "Очищены выбранные ключи Rails.cache"
      }
    rescue StandardError => e
      {
        performed: false,
        mode: "error",
        cleared_keys: [],
        message: "Ошибка очистки кеша: #{e.class} - #{e.message}"
      }
    end

    def load_categories
      scope = case @category_scope
              when "all"
                Category.all
              when "active"
                Category.active
              else
                Category.not_deleted
              end

      scope.to_a
    end

    def find_candidates(entry, categories, by_id)
      leaf_aliases = [entry[:current_name], entry[:expected_name]].compact_blank.uniq
    
      base_candidates = categories.select do |category|
        category_matches_any?(category, leaf_aliases)
      end
    
      return [] if base_candidates.empty?
    
      scored = base_candidates.map do |category|
        score = candidate_match_score(category, entry, by_id)
        [category, score]
      end
    
      best_score = scored.map(&:last).max
    
      if best_score.to_i > 0
        scored
          .select { |_category, score| score == best_score }
          .map(&:first)
          .uniq { |category| category.ikea_id.to_s }
      else
        # fallback: если по leaf-name нашлась ровно одна категория — берём её
        unique = base_candidates.uniq { |category| category.ikea_id.to_s }
        return unique if unique.size == 1
    
        # ещё один fallback: если ровно один кандидат совпал display_name/current_name|expected_name
        exact_name_candidates = unique.select do |category|
          text_equal?(display_name(category), entry[:current_name]) ||
            text_equal?(display_name(category), entry[:expected_name]) ||
            text_equal?(category.translated_name, entry[:current_name]) ||
            text_equal?(category.translated_name, entry[:expected_name]) ||
            text_equal?(category.name, entry[:current_name]) ||
            text_equal?(category.name, entry[:expected_name])
        end
    
        exact_name_candidates = exact_name_candidates.uniq { |category| category.ikea_id.to_s }
        return exact_name_candidates if exact_name_candidates.size == 1
    
        []
      end
    end

    def candidate_match_score(category, entry, by_id)
      db_path = normalized_path(actual_path_for(category, by_id))
    
      variants = [
        normalized_path(entry[:current_path]),
        normalized_path(entry[:expected_full_path])
      ].uniq
    
      best_suffix = variants.map { |variant| suffix_match_length(db_path, variant) }.max.to_i
    
      leaf_score =
        if text_equal?(display_name(category), entry[:expected_name]) || text_equal?(display_name(category), entry[:current_name])
          3
        elsif text_equal?(category.translated_name, entry[:expected_name]) || text_equal?(category.translated_name, entry[:current_name])
          2
        elsif text_equal?(category.name, entry[:expected_name]) || text_equal?(category.name, entry[:current_name])
          1
        else
          0
        end
    
      best_suffix * 10 + leaf_score
    end
    
    def suffix_match_length(db_path, expected_path)
      return 0 if db_path.blank? || expected_path.blank?
    
      max = [db_path.length, expected_path.length].min
    
      max.downto(1) do |len|
        return len if db_path.last(len) == expected_path.last(len)
      end
    
      0
    end

    def resolve_parent_ikea_id(desired_parent_path, expected_path_to_ikea_id, by_id)
      return nil if desired_parent_path.blank?

      expected_match = expected_path_to_ikea_id[normalized_path(desired_parent_path)]
      return expected_match if expected_match.present?

      candidates = by_id.values.select do |category|
        normalized_path(actual_path_for(category, by_id)) == normalized_path(desired_parent_path)
      end

      return candidates.first.ikea_id.to_s if candidates.one?

      nil
    end

    def build_suggested_update(category, entry, hierarchy_ok, display_name_ok, translated_name_ok)
      update = { ikea_id: category.ikea_id.to_s }
      update[:translated_name] = entry[:expected_name] unless translated_name_ok
      update[:expected_parent_path] = entry[:expected_full_path][0...-1] unless hierarchy_ok
      update[:note] = "display_name already matches expected name" if display_name_ok && !translated_name_ok
      update.compact
    end

    def build_totals(results, total_entries)
      grouped = results.group_by { |row| row[:status] }

      {
        rows_in_sheet: total_entries,
        ok: grouped.fetch("ok", []).size,
        not_found: grouped.fetch("not_found", []).size,
        ambiguous: grouped.fetch("ambiguous", []).size,
        with_issues: results.count { |row| row[:status] != "ok" }
      }
    end

    def build_text_report(report)
      lines = []
      lines << "Category sheet audit"
      lines << "Generated at: #{report[:generated_at]}"
      lines << "Sheet URL: #{report[:sheet_url]}"
      lines << "CSV URL: #{report[:csv_url]}"
      lines << "Category scope: #{report[:category_scope]}"
      lines << ""
      lines << "Totals:"
      report[:totals].each do |key, value|
        lines << "  #{key}: #{value}"
      end
      lines << ""
      lines << "Rows with issues:"

      issue_rows = report[:results].reject { |row| row[:status] == "ok" }
      if issue_rows.empty?
        lines << "  none"
      else
        issue_rows.each do |row|
          lines << "- row #{row[:row_number]} | status=#{row[:status]}"
          lines << "  current_path: #{Array(row[:current_path]).join(' > ')}"
          lines << "  expected_full_path: #{Array(row[:expected_full_path]).join(' > ')}"

          case row[:status]
          when "not_found"
            lines << "  message: #{row[:message]}"
          when "ambiguous"
            lines << "  candidates:"
            Array(row[:candidates]).each do |candidate|
              lines << "    - #{candidate[:ikea_id]} | #{candidate[:display_name]} | #{Array(candidate[:db_path]).join(' > ')}"
            end
          else
            db = row[:db] || {}
            lines << "  db_ikea_id: #{db[:ikea_id]}"
            lines << "  db_display_name: #{db[:display_name]}"
            lines << "  db_path: #{Array(db[:db_path]).join(' > ')}"
            lines << "  problems: #{Array(row[:problems]).join(', ')}"
            lines << "  suggested_update: #{JSON.generate(row[:suggested_update])}"
          end

          lines << ""
        end
      end

      lines.join("\n")
    end

    def write_json(filename, payload)
      File.write(File.join(@out_dir, filename), JSON.pretty_generate(payload))
    end

    def write_text(filename, text)
      File.write(File.join(@out_dir, filename), text)
    end

    def actual_path_for(category, by_id)
      ids = Category.normalize_parent_ids(category.parent_ids)
      ids = ids[0...-1] if ids.last == category.ikea_id.to_s

      ancestors = ids.map { |id| by_id[id.to_s] }.compact
      (ancestors + [category]).map { |item| display_name(item) }
    end

    def current_parent_chain_without_self(category)
      ids = Category.normalize_parent_ids(category.parent_ids)
      ids.last == category.ikea_id.to_s ? ids[0...-1] : ids
    end

    def parent_ids_include_self?(category)
      ids = Category.normalize_parent_ids(category.parent_ids)
      ids.last == category.ikea_id.to_s
    end

    def normalized_parent_ids_equal?(left, right)
      Category.normalize_parent_ids(left) == Category.normalize_parent_ids(right)
    end

    def direct_parent_id_for(category)
      Category.direct_parent_id_for(category)&.to_s
    end

    def category_matches_any?(category, names)
      names.any? { |name| category_matches?(category, name) }
    end

    def category_matches?(category, value)
      return false if value.blank?

      category_aliases(category).any? { |candidate| text_equal?(candidate, value) }
    end

    def category_aliases(category)
      [category.name, category.translated_name, display_name(category)].compact_blank.uniq
    end

    def display_name(category)
      category.translated_name.presence || category.name
    end

    def normalized_path(path)
      Array(path).map { |value| normalize_text(value) }
    end

    def text_equal?(left, right)
      normalize_text(left) == normalize_text(right)
    end

    def normalize_text(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]]+/, " ").strip
    end

    def cleanup(value)
      value
        .to_s
        .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        .unicode_normalize(:nfkc)
        .gsub(/\u00A0/, " ")
        .gsub(/[[:space:]]+/, " ")
        .strip
        .presence
    end
  end
end

CategorySheetAudit::Runner.new.call

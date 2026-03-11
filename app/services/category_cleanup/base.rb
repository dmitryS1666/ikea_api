module CategoryCleanup
  class Base
    CATALOG_DIR = Rails.root.join('categories_docs').freeze
    DECISIONS_FILE = CATALOG_DIR.join('catalog_1.ods').freeze
    FULL_CATALOG_FILE = CATALOG_DIR.join('catalog_2.ods').freeze

    private

    def normalize_string(value)
      value.to_s
           .unicode_normalize(:nfkc)
           .downcase
           .gsub(/[[:space:]]+/, ' ')
           .gsub(/[“”"«»]/, '')
           .gsub(/[^\p{Alnum}\p{Cyrillic}\p{Latin}\-\/ ]/u, ' ')
           .squeeze(' ')
           .strip
    end

    def clean_tree_name(value)
      normalize_string(value.to_s.gsub('└─', '').strip)
    end

    def ikea_id_from_url(url)
      return nil if url.blank? || url.to_s == 'нет'
      match = url.to_s.match(/-(\d+)\/?$/)
      match&.captures&.first
    end

    def cache_delete_for_category_ids(*ids)
      ids.flatten.compact.uniq.each do |ikea_id|
        Rails.cache.delete("category_#{ikea_id}_children_count")
      end
    end
  end
end

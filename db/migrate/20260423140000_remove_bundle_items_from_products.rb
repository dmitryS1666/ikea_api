# frozen_string_literal: true

class RemoveBundleItemsFromProducts < ActiveRecord::Migration[7.1]
  def up
    return unless column_exists?(:products, :bundle_items)

    say_with_time "merge bundle_items into included_products" do
      rows = connection.select_all(<<~SQL)
        SELECT id, bundle_items, included_products
        FROM products
        WHERE bundle_items IS NOT NULL
          AND btrim(bundle_items) NOT IN ('', '[]', 'null')
      SQL

      rows.each do |row|
        id = row["id"]
        bi = parse_json_array(row["bundle_items"])
        next if bi.empty?

        ip = parse_json_array(row["included_products"])
        merged = (ip + bi).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        next if merged == ip.map(&:to_s).map(&:strip).reject(&:blank?).uniq

        connection.execute(
          "UPDATE products SET included_products = #{connection.quote(merged.to_json)} WHERE id = #{id.to_i}"
        )
      end
    end

    remove_column :products, :bundle_items, :text
  end

  def down
    add_column :products, :bundle_items, :text
  end

  private

  def parse_json_array(raw)
    return [] if raw.blank?

    parsed = JSON.parse(raw)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end
end

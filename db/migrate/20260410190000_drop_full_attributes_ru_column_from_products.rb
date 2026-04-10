# frozen_string_literal: true

class DropFullAttributesRuColumnFromProducts < ActiveRecord::Migration[7.0]
  def up
    return unless column_exists?(:products, :full_attributes_ru)

    remove_column :products, :full_attributes_ru, :jsonb
  end

  def down
    return if column_exists?(:products, :full_attributes_ru)

    add_column :products, :full_attributes_ru, :jsonb, default: {}, null: false
  end
end

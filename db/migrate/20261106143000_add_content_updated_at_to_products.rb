# frozen_string_literal: true

class AddContentUpdatedAtToProducts < ActiveRecord::Migration[7.1]
  def up
    unless column_exists?(:products, :content_updated_at)
      add_column :products, :content_updated_at, :datetime
    end

    # Текущий updated_at — последняя известная отметка. Дальше она не сдвигается,
    # если ежедневная синхронизация не меняет публикуемые поля карточки.
    execute <<~SQL.squish
      UPDATE products
      SET content_updated_at = updated_at
      WHERE content_updated_at IS NULL
    SQL
  end

  def down
    remove_column :products, :content_updated_at if column_exists?(:products, :content_updated_at)
  end
end

class AddAiTranslatedToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :ai_translated, :boolean
  end
end

class CreateGlobalSeoSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :global_seo_settings do |t|
      t.string :target_type
      t.string :title_template
      t.string :description_template
      t.string :keywords_template
      t.string :robots
      t.text :seo_text

      t.timestamps
    end
  end
end

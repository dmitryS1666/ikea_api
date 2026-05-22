# frozen_string_literal: true

class AddSeoImageAndH1Fields < ActiveRecord::Migration[7.1]
  def change
    change_table :seo_meta, bulk: true do |t|
      t.string :h1
      t.string :image_alt
      t.string :image_title
    end

    change_table :global_seo_settings, bulk: true do |t|
      t.string :image_alt_template
      t.string :image_title_template
      t.string :h1_template
    end
  end
end

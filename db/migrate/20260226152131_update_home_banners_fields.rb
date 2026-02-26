class UpdateHomeBannersFields < ActiveRecord::Migration[7.1]
  def change
    remove_column :home_banners, :title, :string
    remove_column :home_banners, :subtitle, :string
    add_column :home_banners, :description, :text
  end
end

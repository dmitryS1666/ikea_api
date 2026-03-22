class AddCustomUrlToHomeBanners < ActiveRecord::Migration[7.1]
  def change
    add_column :home_banners, :custom_url, :string
  end
end

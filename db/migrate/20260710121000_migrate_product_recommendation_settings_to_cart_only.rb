class MigrateProductRecommendationSettingsToCartOnly < ActiveRecord::Migration[7.1]
  class Setting < ApplicationRecord
    self.table_name = "product_recommendation_settings"
  end

  def up
    homepage_setting = Setting.find_by(placement: 0)
    cart_setting = Setting.find_by(placement: 1)

    if homepage_setting.present?
      if cart_setting.blank?
        homepage_setting.update!(placement: 1)
      else
        if cart_setting.product_skus.blank? && homepage_setting.product_skus.present?
          cart_setting.update!(
            source_type: homepage_setting.source_type,
            active: homepage_setting.active,
            category_id: homepage_setting.category_id,
            product_skus: homepage_setting.product_skus
          )
        end

        homepage_setting.destroy!
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end

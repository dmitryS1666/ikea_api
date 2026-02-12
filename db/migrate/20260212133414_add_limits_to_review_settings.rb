class AddLimitsToReviewSettings < ActiveRecord::Migration[7.1]
  def change
    add_column :review_settings, :min_body_length, :integer, default: 10
    add_column :review_settings, :max_body_length, :integer, default: 2000
    add_column :review_settings, :max_photos_count, :integer, default: 5
  end
end

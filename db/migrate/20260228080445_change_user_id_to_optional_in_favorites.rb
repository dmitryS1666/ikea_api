class ChangeUserIdToOptionalInFavorites < ActiveRecord::Migration[7.1]
  def change
    change_column_null :favorites, :user_id, true
  end
end

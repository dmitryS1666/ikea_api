class AddIconToCategories < ActiveRecord::Migration[7.1]
  def change
    # We will use Active Storage for the icon, so we don't need a column in the table.
    # However, if we want to store a string/URL as a fallback, we could add a column.
    # The user asked for "ability to set a category icon with preview".
    # Active Storage is the standard Rails way for this.
  end
end

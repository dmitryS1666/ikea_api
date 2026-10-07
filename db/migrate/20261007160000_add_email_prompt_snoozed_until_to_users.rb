# frozen_string_literal: true

class AddEmailPromptSnoozedUntilToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :email_prompt_snoozed_until, :datetime
  end
end

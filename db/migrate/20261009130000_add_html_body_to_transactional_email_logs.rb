# frozen_string_literal: true

class AddHtmlBodyToTransactionalEmailLogs < ActiveRecord::Migration[7.1]
  def change
    add_column :transactional_email_logs, :html_body, :text
  end
end

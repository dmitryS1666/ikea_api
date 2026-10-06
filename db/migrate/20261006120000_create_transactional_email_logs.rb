# frozen_string_literal: true

class CreateTransactionalEmailLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :transactional_email_logs do |t|
      t.references :user, foreign_key: true
      t.references :order, foreign_key: true
      t.string :to_email, null: false
      t.string :to_name
      t.string :template_key, null: false
      t.string :subject, null: false
      t.string :preview_text
      t.string :status, null: false, default: "queued"
      t.string :provider, null: false, default: "sendpulse"
      t.string :provider_message_id
      t.text :error_message
      t.datetime :queued_at, null: false
      t.datetime :sent_at
      t.datetime :delivered_at
      t.datetime :opened_at
      t.datetime :failed_at
      t.datetime :last_event_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :transactional_email_logs, :status
    add_index :transactional_email_logs, :template_key
    add_index :transactional_email_logs, :provider_message_id
    add_index :transactional_email_logs, :to_email
    add_index :transactional_email_logs, :created_at
  end
end

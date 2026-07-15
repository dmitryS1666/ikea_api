# frozen_string_literal: true

class CreateAdminOperationsInfrastructure < ActiveRecord::Migration[7.1]
  def change
    add_reference :orders, :assigned_to, foreign_key: { to_table: :users, on_delete: :nullify }
    add_reference :return_requests, :assigned_to, foreign_key: { to_table: :users, on_delete: :nullify }
    add_reference :cooperation_requests, :assigned_to, foreign_key: { to_table: :users, on_delete: :nullify }

    create_table :request_activities do |t|
      t.references :trackable, polymorphic: true, null: false, index: false
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :assignee, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :activity_type, null: false
      t.text :body
      t.string :from_status
      t.string :to_status
      t.jsonb :metadata, null: false, default: {}
      t.timestamps

      t.index [:trackable_type, :trackable_id, :created_at], name: "idx_request_activities_trackable_created"
      t.index [:activity_type, :created_at], name: "idx_request_activities_type_created"
    end

    create_table :finance_entries do |t|
      t.references :order, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :payment_reference
      t.string :invoice_number
      t.decimal :amount, precision: 12, scale: 2, null: false, default: 0
      t.string :currency, null: false, default: "BYN"
      t.string :payment_status, null: false, default: "pending"
      t.string :invoice_status, null: false, default: "not_issued"
      t.string :reconciliation_status, null: false, default: "pending"
      t.datetime :paid_at
      t.datetime :reconciled_at
      t.references :reconciled_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :notes
      t.timestamps

      t.index [:payment_status, :created_at], name: "idx_finance_entries_payment_created"
      t.index [:reconciliation_status, :created_at], name: "idx_finance_entries_reconciliation_created"
      # Номера из legacy payment_order_number не гарантированно уникальны.
      # Уникальность можно включить отдельной миграцией после сверки данных.
      t.index :invoice_number, where: "invoice_number IS NOT NULL"
      t.index :payment_reference
    end

    create_table :admin_audit_logs do |t|
      t.references :actor, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :auditable, polymorphic: true, index: false
      t.string :action, null: false
      t.string :resource, null: false
      t.jsonb :changeset, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.string :request_id
      t.string :ip_address
      t.datetime :created_at, null: false

      t.index [:auditable_type, :auditable_id, :created_at], name: "idx_admin_audit_logs_auditable_created"
      t.index [:actor_id, :created_at], name: "idx_admin_audit_logs_actor_created"
      t.index [:resource, :action, :created_at], name: "idx_admin_audit_logs_resource_action_created"
      t.index :request_id
    end

    reversible do |dir|
      dir.up { backfill_finance_entries }
    end
  end

  private

  def backfill_finance_entries
    paid_statuses = [
      83_329_494, 83_329_498, 83_329_502, 84_842_138, 83_329_506,
      83_329_510, 83_329_514, 83_329_518, 83_329_522, 83_329_526,
      83_329_530, 85_543_826, 142
    ].join(",")

    execute <<~SQL.squish
      INSERT INTO finance_entries (
        order_id, payment_reference, invoice_number, amount, currency,
        payment_status, invoice_status, reconciliation_status, paid_at,
        created_at, updated_at
      )
      SELECT
        id,
        COALESCE(webpay_transaction_id, payment_order_number),
        payment_order_number,
        COALESCE(total_amount, 0),
        'BYN',
        CASE
          WHEN webpay_paid_at IS NOT NULL OR status IN (#{paid_statuses}) THEN 'paid'
          WHEN status = 143 THEN 'failed'
          ELSE 'pending'
        END,
        CASE WHEN payment_order_number IS NOT NULL THEN 'issued' ELSE 'not_issued' END,
        'pending',
        COALESCE(webpay_paid_at, purchased_at),
        created_at,
        updated_at
      FROM orders
      WHERE checkout_draft = FALSE
      ON CONFLICT (order_id) DO NOTHING
    SQL
  end
end

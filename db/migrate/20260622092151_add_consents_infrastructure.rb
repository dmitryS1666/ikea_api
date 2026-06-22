class AddConsentsInfrastructure < ActiveRecord::Migration[7.1]
  def change
    create_table :consent_records do |t|
      t.references :user, null: true, foreign_key: true
      t.references :order, null: true, foreign_key: true
      t.string :consent_type, null: false
      t.boolean :accepted, null: false, default: false
      t.string :legal_page_slug
      t.datetime :legal_page_version_at
      t.string :source, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :consent_records, [:user_id, :consent_type]
    add_index :consent_records, [:order_id, :consent_type]
    add_index :consent_records, :created_at

    change_table :users, bulk: true do |t|
      t.boolean :personal_data_consent, null: false, default: false
      t.datetime :personal_data_consented_at
    end

    change_table :orders, bulk: true do |t|
      t.boolean :personal_data_consent, null: false, default: false
      t.boolean :offer_agreement_consent, null: false, default: false
      t.boolean :customs_broker_consent, null: false, default: false
    end
  end
end

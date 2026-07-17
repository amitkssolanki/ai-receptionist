class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :fulfillment_type, null: false
      t.string :delivery_address
      t.integer :total_cents, null: false, default: 0
      t.text :notes
      t.datetime :placed_at

      t.timestamps
    end
  end
end

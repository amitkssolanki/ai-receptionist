class CreateCustomers < ActiveRecord::Migration[8.1]
  def change
    create_table :customers do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.string :phone_number, null: false
      t.string :name

      t.timestamps
    end

    add_index :customers, [ :restaurant_id, :phone_number ], unique: true
  end
end

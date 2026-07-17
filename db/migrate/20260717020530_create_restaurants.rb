class CreateRestaurants < ActiveRecord::Migration[8.1]
  def change
    create_table :restaurants do |t|
      t.string :name, null: false
      t.string :phone_number, null: false
      t.string :address
      t.string :timezone, null: false, default: "America/New_York"
      t.jsonb :business_hours, null: false, default: {}

      t.timestamps
    end
  end
end

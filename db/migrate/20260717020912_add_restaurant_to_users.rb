class AddRestaurantToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :restaurant, null: false, foreign_key: true
  end
end

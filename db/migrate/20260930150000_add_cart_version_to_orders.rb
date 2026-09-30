# Phase 1 / Step 5: the server owns which cart version is current and which version was last read back.
class AddCartVersionToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :cart_version, :integer, null: false, default: 0
    add_column :orders, :read_back_version, :integer
    add_column :orders, :read_back_at, :datetime, precision: 3
  end
end

class CreateMenuItemModifiers < ActiveRecord::Migration[8.1]
  def change
    create_table :menu_item_modifiers do |t|
      t.references :menu_item, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :price_cents, null: false, default: 0
      t.integer :position

      t.timestamps
    end
  end
end

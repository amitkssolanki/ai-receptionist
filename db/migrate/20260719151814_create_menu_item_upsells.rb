class CreateMenuItemUpsells < ActiveRecord::Migration[8.1]
  def change
    create_table :menu_item_upsells do |t|
      t.references :menu_item, null: false, foreign_key: true
      t.references :upsell_item, null: false, foreign_key: { to_table: :menu_items }

      t.timestamps
    end

    add_index :menu_item_upsells, [ :menu_item_id, :upsell_item_id ], unique: true, name: "index_menu_item_upsells_uniqueness"
  end
end

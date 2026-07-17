class CreateMenuCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :menu_categories do |t|
      t.references :restaurant, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :position

      t.timestamps
    end
  end
end

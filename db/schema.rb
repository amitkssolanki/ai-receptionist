# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_17_020912) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "call_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "customer_id"
    t.datetime "ended_at"
    t.string "external_call_id", null: false
    t.bigint "order_id"
    t.string "phone_number", null: false
    t.string "recording_url"
    t.bigint "restaurant_id", null: false
    t.datetime "started_at"
    t.string "status", default: "in_progress", null: false
    t.text "transcript"
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_call_logs_on_customer_id"
    t.index ["external_call_id"], name: "index_call_logs_on_external_call_id", unique: true
    t.index ["order_id"], name: "index_call_logs_on_order_id"
    t.index ["restaurant_id"], name: "index_call_logs_on_restaurant_id"
  end

  create_table "customers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.string "phone_number", null: false
    t.bigint "restaurant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["restaurant_id", "phone_number"], name: "index_customers_on_restaurant_id_and_phone_number", unique: true
    t.index ["restaurant_id"], name: "index_customers_on_restaurant_id"
  end

  create_table "menu_categories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position"
    t.bigint "restaurant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["restaurant_id"], name: "index_menu_categories_on_restaurant_id"
  end

  create_table "menu_item_modifiers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "menu_item_id", null: false
    t.string "name", null: false
    t.integer "position"
    t.integer "price_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["menu_item_id"], name: "index_menu_item_modifiers_on_menu_item_id"
  end

  create_table "menu_items", force: :cascade do |t|
    t.boolean "available", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "menu_category_id", null: false
    t.string "name", null: false
    t.integer "position"
    t.integer "price_cents", null: false
    t.bigint "restaurant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["menu_category_id"], name: "index_menu_items_on_menu_category_id"
    t.index ["restaurant_id"], name: "index_menu_items_on_restaurant_id"
  end

  create_table "order_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "menu_item_id", null: false
    t.string "notes"
    t.bigint "order_id", null: false
    t.integer "quantity", default: 1, null: false
    t.jsonb "selected_modifiers", default: [], null: false
    t.integer "unit_price_cents", null: false
    t.datetime "updated_at", null: false
    t.index ["menu_item_id"], name: "index_order_items_on_menu_item_id"
    t.index ["order_id"], name: "index_order_items_on_order_id"
  end

  create_table "orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "customer_id", null: false
    t.string "delivery_address"
    t.string "fulfillment_type", null: false
    t.text "notes"
    t.datetime "placed_at"
    t.bigint "restaurant_id", null: false
    t.string "status", default: "pending", null: false
    t.integer "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_orders_on_customer_id"
    t.index ["restaurant_id"], name: "index_orders_on_restaurant_id"
  end

  create_table "restaurants", force: :cascade do |t|
    t.string "address"
    t.jsonb "business_hours", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "phone_number", null: false
    t.string "timezone", default: "America/New_York", null: false
    t.datetime "updated_at", null: false
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.bigint "restaurant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["restaurant_id"], name: "index_users_on_restaurant_id"
  end

  add_foreign_key "call_logs", "customers"
  add_foreign_key "call_logs", "orders"
  add_foreign_key "call_logs", "restaurants"
  add_foreign_key "customers", "restaurants"
  add_foreign_key "menu_categories", "restaurants"
  add_foreign_key "menu_item_modifiers", "menu_items"
  add_foreign_key "menu_items", "menu_categories"
  add_foreign_key "menu_items", "restaurants"
  add_foreign_key "order_items", "menu_items"
  add_foreign_key "order_items", "orders"
  add_foreign_key "orders", "customers"
  add_foreign_key "orders", "restaurants"
  add_foreign_key "users", "restaurants"
end

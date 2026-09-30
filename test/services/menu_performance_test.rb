require "test_helper"

# Regression guard for the Phase 0 measurements (docs/phase1/PLAN.md section 7), using the real 20-item Taj Zayka
# menu from the frozen baseline snapshot.
#
#                      queries   bytes
#   get_menu before       51      4,554   (Restaurant#voice_menu_json, measured at portfolio-baseline)
#   get_menu after         3     <= 1,600 (MenuCatalog#overview)
#   get_menu_item          3      small   (MenuCatalog#item)
class MenuPerformanceTest < ActiveSupport::TestCase
  BASELINE_DIR = Rails.root.join("test/fixtures/files/baseline")
  OVERVIEW_BYTE_BUDGET = 1600

  setup do
    snapshot = JSON.parse(BASELINE_DIR.join("db_snapshot.json").read)
    restaurant = snapshot["restaurant"]
    @restaurant = Restaurant.create!(id: restaurant["id"], name: restaurant["name"], phone_number: "+15550001111", timezone: restaurant["timezone"])
    menu = snapshot["menu_reference"]
    menu["categories"].each { |c| @restaurant.menu_categories.create!(id: c["id"], name: c["name"], position: c["position"]) }
    menu["items"].each do |i|
      MenuItem.create!(i.slice("id", "menu_category_id", "name", "description", "price_cents", "available", "position").merge(restaurant: @restaurant))
    end
    menu["modifiers"].each { |m| MenuItemModifier.create!(m.slice("id", "menu_item_id", "name", "price_cents", "position")) }
    menu["upsells"].each { |u| MenuItemUpsell.create!(u.slice("id", "menu_item_id", "upsell_item_id")) }
    # Rows above were inserted with explicit ids; move the sequences past them so later creates don't collide.
    %w[restaurants menu_categories menu_items menu_item_modifiers menu_item_upsells].each { |t| ActiveRecord::Base.connection.reset_pk_sequence!(t) }
    @catalog = MenuCatalog.new(@restaurant)
  end

  def double_the_menu!
    @restaurant.menu_categories.to_a.each do |category|
      copy = @restaurant.menu_categories.create!(name: "#{category.name} 2", position: category.position + 100)
      category.menu_items.each do |item|
        twin = copy.menu_items.create!(restaurant: @restaurant, name: "#{item.name} 2", description: item.description, price_cents: item.price_cents)
        item.menu_item_modifiers.each { |m| twin.menu_item_modifiers.create!(name: m.name, price_cents: m.price_cents) }
      end
    end
  end

  test "the fixture is the real menu the baseline was measured on" do
    assert_equal [ 6, 20 ], [ @restaurant.menu_categories.count, @restaurant.menu_items.available.count ]
  end

  test "get_menu takes 3 queries on the real menu" do
    assert_queries_count(3) { @catalog.overview }
  end

  test "get_menu still takes 3 queries when the menu doubles" do
    double_the_menu!
    assert_equal 40, @restaurant.menu_items.available.count
    assert_queries_count(3) { @catalog.overview }
  end

  test "get_menu_item takes no more than 4 queries, however many pairings or modifiers the item has" do
    item = @restaurant.menu_items.joins(:menu_item_modifiers).first
    assert_queries_count(3) { @catalog.item(item.id) }
    assert_queries_count(1) { @catalog.item(0) }
  end

  test "the serialized get_menu result fits the 1,600 byte budget (was 4,554)" do
    bytes = { ok: true, categories: @catalog.overview }.to_json.bytesize
    assert_operator bytes, :<=, OVERVIEW_BYTE_BUDGET, "get_menu is #{bytes} bytes"
    puts "\n[menu] get_menu payload: #{bytes} bytes" if ENV["MENU_VERBOSE"]
  end

  test "the same budget holds through the tool runner, including its envelope" do
    call = @restaurant.call_logs.create!(external_call_id: "perf", customer: @restaurant.customers.create!(phone_number: "unknown-perf"), phone_number: "unknown-perf")
    result = Voice::ToolRunner.call(call_log: call, tool_call: { "id" => "t1", "function" => { "name" => "get_menu", "arguments" => {} } })
    assert_operator result.bytesize, :<=, OVERVIEW_BYTE_BUDGET
    assert_equal 20, JSON.parse(result)["categories"].sum { |c| c["items"].size }
  end
end

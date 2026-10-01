require "test_helper"

class MenuCatalogTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(name: "Menu Bistro", phone_number: "+15550006666")
    @pizzas = @restaurant.menu_categories.create!(name: "Pizzas", position: 1)
    @sides = @restaurant.menu_categories.create!(name: "Sides", position: 2)
    @pizza = @pizzas.menu_items.create!(restaurant: @restaurant, name: "Margherita", description: "Basil", price_cents: 1400, position: 1)
    @knots = @sides.menu_items.create!(restaurant: @restaurant, name: "Knots", price_cents: 550, position: 1)
    @sold_out = @sides.menu_items.create!(restaurant: @restaurant, name: "Sold out", price_cents: 100, available: false, position: 2)
    @cheese = @pizza.menu_item_modifiers.create!(name: "Extra cheese", price_cents: 200)
    @pizza.menu_item_upsells.create!(upsell_item: @knots)
    @pizza.menu_item_upsells.create!(upsell_item: @sold_out)
    @catalog = MenuCatalog.new(@restaurant)
  end

  test "overview is compact: ids, names, prices and whether an item is customizable" do
    assert_equal(
      [ { category: "Pizzas", items: [ { id: @pizza.id, name: "Margherita", price: 14.0, customizable: true } ] },
        { category: "Sides", items: [ { id: @knots.id, name: "Knots", price: 5.5, customizable: false } ] } ],
      @catalog.overview
    )
  end

  test "overview leaves out unavailable items, categories with nothing orderable, and other restaurants" do
    @restaurant.menu_categories.create!(name: "Empty", position: 3)
    all_sold_out = @restaurant.menu_categories.create!(name: "Sold out category", position: 4)
    all_sold_out.menu_items.create!(restaurant: @restaurant, name: "Gone", price_cents: 100, available: false)
    other = Restaurant.create!(name: "Other", phone_number: "+15550006667")
    other.menu_categories.create!(name: "Other pizzas", position: 1).menu_items.create!(restaurant: other, name: "Foreign", price_cents: 100)

    overview = @catalog.overview
    assert_equal %w[Pizzas Sides], overview.map { |c| c[:category] }
    assert_equal %w[Margherita Knots], overview.flat_map { |c| c[:items].map { |i| i[:name] } }
  end

  test "items keep their menu position order" do
    @pizzas.menu_items.create!(restaurant: @restaurant, name: "Zesty", price_cents: 100, position: 0)
    assert_equal %w[Zesty Margherita], @catalog.overview.first[:items].map { |i| i[:name] }
  end

  test "item returns description, modifiers and only available pairings" do
    assert_equal(
      { id: @pizza.id, name: "Margherita", description: "Basil", price: 14.0,
        modifiers: [ { id: @cheese.id, name: "Extra cheese", price: 2.0 } ],
        suggest_with: [ { id: @knots.id, name: "Knots", price: 5.5 } ] },
      @catalog.item(@pizza.id)
    )
    assert_equal [], @catalog.item(@knots.id)[:modifiers]
  end

  test "item is nil for unknown, sold-out and other-restaurant items" do
    other = Restaurant.create!(name: "Other", phone_number: "+15550006667")
    foreign = other.menu_categories.create!(name: "X", position: 1).menu_items.create!(restaurant: other, name: "Foreign", price_cents: 100)
    [ 0, @sold_out.id, foreign.id ].each { |id| assert_nil @catalog.item(id), id }
  end
end

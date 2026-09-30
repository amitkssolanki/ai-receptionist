require "test_helper"

class MenuCatalogTest < ActiveSupport::TestCase
  test "full lists categories with available items only, including modifiers and pairings" do
    restaurant = Restaurant.create!(name: "Menu Bistro", phone_number: "+15550006666")
    pizzas = restaurant.menu_categories.create!(name: "Pizzas", position: 1)
    sides = restaurant.menu_categories.create!(name: "Sides", position: 2)
    pizza = pizzas.menu_items.create!(restaurant: restaurant, name: "Margherita", description: "Basil", price_cents: 1400)
    knots = sides.menu_items.create!(restaurant: restaurant, name: "Knots", price_cents: 550)
    sides.menu_items.create!(restaurant: restaurant, name: "Sold out", price_cents: 100, available: false)
    cheese = pizza.menu_item_modifiers.create!(name: "Extra cheese", price_cents: 200)
    pizza.menu_item_upsells.create!(upsell_item: knots)

    menu = MenuCatalog.new(restaurant).full

    assert_equal %w[Pizzas Sides], menu.map { |c| c[:category] }
    assert_equal(
      { id: pizza.id, name: "Margherita", description: "Basil", price: 14.0,
        modifiers: [ { id: cheese.id, name: "Extra cheese", price: 2.0 } ],
        suggest_with: [ { id: knots.id, name: "Knots", price: 5.5 } ] },
      menu.first[:items].sole
    )
    assert_equal [ "Knots" ], menu.last[:items].map { |i| i[:name] }
  end
end

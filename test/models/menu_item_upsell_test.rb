require "test_helper"

class MenuItemUpsellTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(name: "Test Bistro", phone_number: "+15550004444")
    @category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = @category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @fries = @category.menu_items.create!(restaurant: @restaurant, name: "Fries", price_cents: 400)
  end

  test "an item cannot upsell itself" do
    upsell = MenuItemUpsell.new(menu_item: @burger, upsell_item: @burger)
    assert_not upsell.valid?
    assert_includes upsell.errors[:upsell_item], "can't be the same as the menu item"
  end

  test "the same pairing cannot be added twice" do
    MenuItemUpsell.create!(menu_item: @burger, upsell_item: @fries)
    duplicate = MenuItemUpsell.new(menu_item: @burger, upsell_item: @fries)
    assert_not duplicate.valid?
  end

  test "upsell_items reflects the pairing" do
    MenuItemUpsell.create!(menu_item: @burger, upsell_item: @fries)
    assert_equal [ @fries ], @burger.upsell_items
  end
end

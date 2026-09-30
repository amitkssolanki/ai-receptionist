# What a voice agent is allowed to know about a restaurant's menu. Step 2 moves the existing get_menu shape here
# unchanged (it replaces Restaurant#voice_menu_json); the compact overview / per-item lookups arrive in Step 8.
class MenuCatalog
  def initialize(restaurant)
    @restaurant = restaurant
  end

  def full
    @restaurant.menu_categories.includes(menu_items: [ :menu_item_modifiers, :upsell_items ]).map do |category|
      {
        category: category.name,
        items: category.menu_items.available.map do |item|
          {
            id: item.id,
            name: item.name,
            description: item.description,
            price: item.price,
            modifiers: item.menu_item_modifiers.map { |m| { id: m.id, name: m.name, price: m.price_cents / 100.0 } },
            suggest_with: item.upsell_items.available.map { |u| { id: u.id, name: u.name, price: u.price } }
          }
        end
      }
    end
  end
end

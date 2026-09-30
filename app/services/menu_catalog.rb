# What a voice agent is allowed to know about a restaurant's menu, in two sizes so a phone call never has to
# recite (or be sent) more than it needs:
#   overview - categories with id, name, price and whether an item is customizable. A constant number of queries.
#   item(id) - one item's description, modifiers and suggested pairings, for when the caller asks about it.
# Everything is scoped to the restaurant and to available items; nothing else is preloaded.
class MenuCatalog
  def initialize(restaurant)
    @restaurant = restaurant
  end

  # 3 queries (categories, available items, which items have modifiers) however large the menu is.
  # Categories with nothing orderable in them are left out.
  def overview
    categories = MenuCategory.where(restaurant: @restaurant).order(:position, :id).to_a
    items = @restaurant.menu_items.available.order(:position, :id).to_a
    customizable = MenuItemModifier.where(menu_item_id: items.map(&:id)).distinct.pluck(:menu_item_id).to_set
    items_by_category = items.group_by(&:menu_category_id)

    categories.filter_map do |category|
      listed = items_by_category.fetch(category.id, []).map do |item|
        { id: item.id, name: item.name, price: item.price, customizable: customizable.include?(item.id) }
      end
      { category: category.name, items: listed } if listed.any?
    end
  end

  # Returns nil when the item doesn't exist, isn't available, or belongs to another restaurant. 3 queries.
  def item(id)
    menu_item = @restaurant.menu_items.available.find_by(id: id)
    return unless menu_item

    {
      id: menu_item.id,
      name: menu_item.name,
      description: menu_item.description,
      price: menu_item.price,
      modifiers: menu_item.menu_item_modifiers.map { |m| { id: m.id, name: m.name, price: m.price_cents / 100.0 } },
      suggest_with: pairings(menu_item)
    }
  end

  # Available items worth suggesting alongside this one.
  def pairings(menu_item)
    menu_item.upsell_items.available.map { |u| { id: u.id, name: u.name, price: u.price } }
  end
end

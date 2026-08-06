restaurant = Restaurant.find_or_create_by!(name: "Taj Zayka") do |r|
  r.phone_number = "+15551234567"
  r.address = "123 Main St, Springfield"
  r.timezone = "America/New_York"
  r.business_hours = {
    "mon" => "00:00-23:59", "tue" => "00:00-23:59", "wed" => "00:00-23:59",
    "thu" => "00:00-23:59", "fri" => "00:00-23:59", "sat" => "00:00-23:59", "sun" => "00:00-23:59"
  }
end

User.find_or_create_by!(email: "admin@example.com") do |u|
  u.password = "password123"
  u.restaurant = restaurant
end

starters = restaurant.menu_categories.find_or_create_by!(name: "Starters") { |c| c.position = 1 }
mains = restaurant.menu_categories.find_or_create_by!(name: "Mains") { |c| c.position = 2 }
pizzas = restaurant.menu_categories.find_or_create_by!(name: "Pizzas") { |c| c.position = 3 }
sides = restaurant.menu_categories.find_or_create_by!(name: "Sides") { |c| c.position = 4 }
drinks = restaurant.menu_categories.find_or_create_by!(name: "Drinks") { |c| c.position = 5 }
combos = restaurant.menu_categories.find_or_create_by!(name: "Combos") { |c| c.position = 6 }

# Starters

calamari = starters.menu_items.find_or_create_by!(name: "Fried Calamari") do |item|
  item.restaurant = restaurant
  item.description = "Crispy calamari with marinara sauce"
  item.price_cents = 1400
  item.position = 1
end

mozzarella_sticks = starters.menu_items.find_or_create_by!(name: "Mozzarella Sticks") do |item|
  item.restaurant = restaurant
  item.description = "Breaded mozzarella, marinara for dipping"
  item.price_cents = 950
  item.position = 2
end

# Mains

burger = mains.menu_items.find_or_create_by!(name: "Bistro Burger") do |item|
  item.restaurant = restaurant
  item.description = "Half-pound burger with cheddar, lettuce, tomato"
  item.price_cents = 1800
  item.position = 1
end
burger.menu_item_modifiers.find_or_create_by!(name: "Add bacon") { |m| m.price_cents = 200; m.position = 1 }
burger.menu_item_modifiers.find_or_create_by!(name: "Add avocado") { |m| m.price_cents = 250; m.position = 2 }

chicken_sandwich = mains.menu_items.find_or_create_by!(name: "Grilled Chicken Sandwich") do |item|
  item.restaurant = restaurant
  item.description = "Grilled chicken breast, lettuce, tomato, garlic aioli on a brioche bun"
  item.price_cents = 1600
  item.position = 2
end
chicken_sandwich.menu_item_modifiers.find_or_create_by!(name: "Add bacon") { |m| m.price_cents = 300; m.position = 1 }
chicken_sandwich.menu_item_modifiers.find_or_create_by!(name: "Add cheese") { |m| m.price_cents = 150; m.position = 2 }
chicken_sandwich.menu_item_modifiers.find_or_create_by!(name: "Gluten-free bun") { |m| m.price_cents = 200; m.position = 3 }

# Pizzas

margherita = pizzas.menu_items.find_or_create_by!(name: "Margherita Pizza") do |item|
  item.restaurant = restaurant
  item.description = "Fresh mozzarella, basil, San Marzano tomato sauce"
  item.price_cents = 1400
  item.position = 1
end
margherita.menu_item_modifiers.find_or_create_by!(name: "Extra cheese") { |m| m.price_cents = 200; m.position = 1 }
margherita.menu_item_modifiers.find_or_create_by!(name: "Add pepperoni") { |m| m.price_cents = 250; m.position = 2 }
margherita.menu_item_modifiers.find_or_create_by!(name: "Gluten-free crust") { |m| m.price_cents = 300; m.position = 3 }

pepperoni = pizzas.menu_items.find_or_create_by!(name: "Pepperoni Pizza") do |item|
  item.restaurant = restaurant
  item.description = "Classic pepperoni, mozzarella, tomato sauce"
  item.price_cents = 1550
  item.position = 2
end
pepperoni.menu_item_modifiers.find_or_create_by!(name: "Extra cheese") { |m| m.price_cents = 200; m.position = 1 }
pepperoni.menu_item_modifiers.find_or_create_by!(name: "Extra pepperoni") { |m| m.price_cents = 250; m.position = 2 }
pepperoni.menu_item_modifiers.find_or_create_by!(name: "Stuffed crust") { |m| m.price_cents = 350; m.position = 3 }

bbq_chicken_pizza = pizzas.menu_items.find_or_create_by!(name: "BBQ Chicken Pizza") do |item|
  item.restaurant = restaurant
  item.description = "Grilled chicken, red onion, BBQ sauce, mozzarella"
  item.price_cents = 1650
  item.position = 3
end
bbq_chicken_pizza.menu_item_modifiers.find_or_create_by!(name: "Extra chicken") { |m| m.price_cents = 300; m.position = 1 }
bbq_chicken_pizza.menu_item_modifiers.find_or_create_by!(name: "Add jalapenos") { |m| m.price_cents = 100; m.position = 2 }

veggie_supreme = pizzas.menu_items.find_or_create_by!(name: "Veggie Supreme Pizza") do |item|
  item.restaurant = restaurant
  item.description = "Bell peppers, mushrooms, red onion, olives, mozzarella"
  item.price_cents = 1500
  item.position = 4
end
veggie_supreme.menu_item_modifiers.find_or_create_by!(name: "Add extra veggies") { |m| m.price_cents = 150; m.position = 1 }
veggie_supreme.menu_item_modifiers.find_or_create_by!(name: "Vegan cheese") { |m| m.price_cents = 250; m.position = 2 }

# Sides

fries = sides.menu_items.find_or_create_by!(name: "French Fries") do |item|
  item.restaurant = restaurant
  item.description = "Crispy golden fries, salted"
  item.price_cents = 450
  item.position = 1
end

garlic_knots = sides.menu_items.find_or_create_by!(name: "Garlic Knots") do |item|
  item.restaurant = restaurant
  item.description = "Baked dough knots tossed in garlic butter and parmesan"
  item.price_cents = 550
  item.position = 2
end

garden_salad = sides.menu_items.find_or_create_by!(name: "Garden Salad") do |item|
  item.restaurant = restaurant
  item.description = "Mixed greens, tomato, cucumber, choice of dressing"
  item.price_cents = 500
  item.position = 3
end

onion_rings = sides.menu_items.find_or_create_by!(name: "Onion Rings") do |item|
  item.restaurant = restaurant
  item.description = "Beer-battered onion rings"
  item.price_cents = 550
  item.position = 4
end

# Drinks

coke = drinks.menu_items.find_or_create_by!(name: "Coca-Cola") do |item|
  item.restaurant = restaurant
  item.description = "Canned, 12oz"
  item.price_cents = 250
  item.position = 1
end

sprite = drinks.menu_items.find_or_create_by!(name: "Sprite") do |item|
  item.restaurant = restaurant
  item.description = "Canned, 12oz"
  item.price_cents = 250
  item.position = 2
end

bottled_water = drinks.menu_items.find_or_create_by!(name: "Bottled Water") do |item|
  item.restaurant = restaurant
  item.description = "16.9oz bottle"
  item.price_cents = 200
  item.position = 3
end

iced_tea = drinks.menu_items.find_or_create_by!(name: "Iced Tea") do |item|
  item.restaurant = restaurant
  item.description = "Freshly brewed, sweetened or unsweetened"
  item.price_cents = 300
  item.position = 4
end
iced_tea.menu_item_modifiers.find_or_create_by!(name: "Add lemon") { |m| m.price_cents = 0; m.position = 1 }

lemonade = drinks.menu_items.find_or_create_by!(name: "Lemonade") do |item|
  item.restaurant = restaurant
  item.description = "Fresh-squeezed lemonade"
  item.price_cents = 350
  item.position = 5
end

# Combos - modifiers here double as "pick one" choices (side/drink) since there's
# no modifier-group concept yet; each choice is priced at $0 unless it's an upgrade.

burger_combo = combos.menu_items.find_or_create_by!(name: "Burger Combo") do |item|
  item.restaurant = restaurant
  item.description = "Bistro Burger with fries and a drink"
  item.price_cents = 2299
  item.position = 1
end
burger_combo.menu_item_modifiers.find_or_create_by!(name: "Swap fries for garden salad") { |m| m.price_cents = 100; m.position = 1 }
burger_combo.menu_item_modifiers.find_or_create_by!(name: "Swap fries for onion rings") { |m| m.price_cents = 150; m.position = 2 }
burger_combo.menu_item_modifiers.find_or_create_by!(name: "Drink: Coca-Cola") { |m| m.price_cents = 0; m.position = 3 }
burger_combo.menu_item_modifiers.find_or_create_by!(name: "Drink: Sprite") { |m| m.price_cents = 0; m.position = 4 }
burger_combo.menu_item_modifiers.find_or_create_by!(name: "Drink: Bottled Water") { |m| m.price_cents = 0; m.position = 5 }
burger_combo.menu_item_modifiers.find_or_create_by!(name: "Drink: Iced Tea") { |m| m.price_cents = 0; m.position = 6 }

slice_combo = combos.menu_items.find_or_create_by!(name: "Slice & Drink Combo") do |item|
  item.restaurant = restaurant
  item.description = "One slice of pepperoni or cheese pizza with a fountain drink"
  item.price_cents = 799
  item.position = 2
end
slice_combo.menu_item_modifiers.find_or_create_by!(name: "Upgrade to two slices") { |m| m.price_cents = 350; m.position = 1 }
slice_combo.menu_item_modifiers.find_or_create_by!(name: "Add side salad") { |m| m.price_cents = 200; m.position = 2 }

pizza_lunch_combo = combos.menu_items.find_or_create_by!(name: "Pizza Lunch Combo") do |item|
  item.restaurant = restaurant
  item.description = "Personal 8-inch pizza with a side and a drink"
  item.price_cents = 1299
  item.position = 3
end
pizza_lunch_combo.menu_item_modifiers.find_or_create_by!(name: "Side: Garden Salad") { |m| m.price_cents = 0; m.position = 1 }
pizza_lunch_combo.menu_item_modifiers.find_or_create_by!(name: "Side: Garlic Knots") { |m| m.price_cents = 0; m.position = 2 }
pizza_lunch_combo.menu_item_modifiers.find_or_create_by!(name: "Side: French Fries") { |m| m.price_cents = 0; m.position = 3 }
pizza_lunch_combo.menu_item_modifiers.find_or_create_by!(name: "Drink: Coca-Cola") { |m| m.price_cents = 0; m.position = 4 }
pizza_lunch_combo.menu_item_modifiers.find_or_create_by!(name: "Drink: Sprite") { |m| m.price_cents = 0; m.position = 5 }
pizza_lunch_combo.menu_item_modifiers.find_or_create_by!(name: "Drink: Bottled Water") { |m| m.price_cents = 0; m.position = 6 }

# Upsell suggestions

burger.menu_item_upsells.find_or_create_by!(upsell_item: fries)
margherita.menu_item_upsells.find_or_create_by!(upsell_item: garlic_knots)
margherita.menu_item_upsells.find_or_create_by!(upsell_item: coke)
pepperoni.menu_item_upsells.find_or_create_by!(upsell_item: garlic_knots)
chicken_sandwich.menu_item_upsells.find_or_create_by!(upsell_item: garden_salad)

puts "Seeded #{restaurant.name} with #{restaurant.menu_items.count} menu items across #{restaurant.menu_categories.count} categories."
puts "Admin login: admin@example.com / password123"

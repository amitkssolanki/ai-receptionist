restaurant = Restaurant.find_or_create_by!(name: "Sample Bistro") do |r|
  r.phone_number = "+15551234567"
  r.address = "123 Main St, Springfield"
  r.timezone = "America/New_York"
  r.business_hours = {
    "mon" => "11:00-21:00", "tue" => "11:00-21:00", "wed" => "11:00-21:00",
    "thu" => "11:00-21:00", "fri" => "11:00-22:00", "sat" => "11:00-22:00", "sun" => "closed"
  }
end

User.find_or_create_by!(email: "admin@example.com") do |u|
  u.password = "password123"
  u.restaurant = restaurant
end

starters = restaurant.menu_categories.find_or_create_by!(name: "Starters") { |c| c.position = 1 }
mains = restaurant.menu_categories.find_or_create_by!(name: "Mains") { |c| c.position = 2 }

calamari = starters.menu_items.find_or_create_by!(name: "Fried Calamari") do |item|
  item.restaurant = restaurant
  item.description = "Crispy calamari with marinara sauce"
  item.price_cents = 1400
  item.position = 1
end

burger = mains.menu_items.find_or_create_by!(name: "Bistro Burger") do |item|
  item.restaurant = restaurant
  item.description = "Half-pound burger with cheddar, lettuce, tomato"
  item.price_cents = 1800
  item.position = 1
end

burger.menu_item_modifiers.find_or_create_by!(name: "Add bacon") { |m| m.price_cents = 200; m.position = 1 }
burger.menu_item_modifiers.find_or_create_by!(name: "Add avocado") { |m| m.price_cents = 250; m.position = 2 }

puts "Seeded #{restaurant.name} with #{restaurant.menu_items.count} menu items."
puts "Admin login: admin@example.com / password123"

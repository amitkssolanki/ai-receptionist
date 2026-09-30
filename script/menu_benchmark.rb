# Read-only benchmark of the voice menu against the development database (Phase 1 / Step 6).
#
#   bin/rails runner script/menu_benchmark.rb
#
# Works on both sides of the optimization, so the same file measures the tag and the branch:
#   before: Restaurant#voice_menu_json   (portfolio-baseline)
#   after:  MenuCatalog#overview / #item
require "json"

restaurant = Restaurant.first or abort "no restaurant in #{Rails.env} database"

def measure(runs: 50)
  queries = 0
  counter = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
    queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i)
  end
  result = yield
  ActiveSupport::Notifications.unsubscribe(counter)

  times = Array.new(runs) do
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
  end
  [ result, queries, times.sort[runs / 2] ]
end

report = lambda do |label, (result, queries, median_ms)|
  puts format("%-28s %3d queries  %6d bytes  median %.1f ms (50 runs)", label, queries, result.to_json.bytesize, median_ms)
end

items = restaurant.menu_items.available.count
puts "#{restaurant.name}: #{restaurant.menu_categories.count} categories, #{items} available items"

if restaurant.respond_to?(:voice_menu_json)
  report.call("get_menu (before)", measure { restaurant.voice_menu_json })
else
  catalog = MenuCatalog.new(restaurant)
  report.call("get_menu (overview)", measure { catalog.overview })
  item_id = restaurant.menu_items.available.joins(:menu_item_modifiers).first&.id || restaurant.menu_items.available.first.id
  report.call("get_menu_item", measure { catalog.item(item_id) })
end

module Evaluation
  # The menu of the real Taj Zayka (from the frozen Phase 0 snapshot), created fresh for a scenario so that scripted tool
  # calls can name items instead of hard-coding database ids.
  class World
    SNAPSHOT = Rails.root.join("test/fixtures/files/baseline/db_snapshot.json")

    attr_reader :restaurant, :call_log
    attr_accessor :last_read_back_version

    def initialize(call_id:)
      data = JSON.parse(SNAPSHOT.read)
      @restaurant = Restaurant.create!(name: "Evaluation Taj Zayka", phone_number: "+15550100#{rand(1000..9999)}",
                                       timezone: data.dig("restaurant", "timezone"), business_hours: ALWAYS_OPEN)
      build_menu(data["menu_reference"])
      @call_log = CallLifecycle.start(external_call_id: call_id, dialed_number: @restaurant.phone_number, caller_number: nil)
    end

    ALWAYS_OPEN = %w[sun mon tue wed thu fri sat].index_with { "24h" }.freeze

    def item_id(name) = items.fetch(name).id
    def modifier_id(item_name, modifier_name) = items.fetch(item_name).menu_item_modifiers.find_by!(name: modifier_name).id
    def first_line_id = call_log.reload.order.order_items.order(:id).first.id
    def item_names = items.keys

    private

    def items = @items ||= {}

    def build_menu(menu)
      categories = menu["categories"].to_h { |c| [ c["id"], restaurant.menu_categories.create!(name: c["name"], position: c["position"]) ] }
      by_old_id = menu["items"].to_h do |i|
        [ i["id"], categories.fetch(i["menu_category_id"]).menu_items.create!(restaurant: restaurant, name: i["name"], description: i["description"],
                                                                              price_cents: i["price_cents"], available: i["available"], position: i["position"]) ]
      end
      menu["modifiers"].each { |m| by_old_id.fetch(m["menu_item_id"]).menu_item_modifiers.create!(name: m["name"], price_cents: m["price_cents"], position: m["position"]) }
      menu["upsells"].each { |u| MenuItemUpsell.create!(menu_item: by_old_id.fetch(u["menu_item_id"]), upsell_item: by_old_id.fetch(u["upsell_item_id"])) }
      by_old_id.each_value { |item| items[item.name] = item }
    end
  end
end

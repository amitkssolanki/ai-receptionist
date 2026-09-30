require "test_helper"

# Step 4 invariants, one focused test each. R-suite coverage lives in test/baseline.
class OrderTakingRulesTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(name: "Rules Bistro", phone_number: "+15550008888", business_hours: ALWAYS_OPEN_HOURS)
    @category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = @category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @cheese = @burger.menu_item_modifiers.create!(name: "Cheese", price_cents: 150)
    @fries = @category.menu_items.create!(restaurant: @restaurant, name: "Fries", price_cents: 400)
    @bacon = @fries.menu_item_modifiers.create!(name: "Bacon", price_cents: 100)
    customer = @restaurant.customers.create!(phone_number: "unknown-rules")
    @call_log = @restaurant.call_logs.create!(external_call_id: "rules_call", customer: customer, phone_number: "unknown-rules")
    @service = OrderTaking.new(@call_log)
  end

  def order = @call_log.reload.order

  def add(item = @burger, **opts) = OrderTaking.new(@call_log.reload).add_item(menu_item_id: item.id, **opts)

  # --- quantity bounds ---

  test "quantity 1 and 20 are accepted; 0, 21 and negatives are refused without touching the cart" do
    assert_not_predicate add(quantity: 1), :rejected?
    assert_not_predicate add(quantity: 20), :rejected?
    [ 0, 21, -1, 500 ].each { |q| assert_equal :quantity_out_of_range, add(quantity: q).rejection, q }
    assert_equal [ 1, 20 ], order.order_items.map(&:quantity)
  end

  test "a refused first add does not create an order" do
    assert_equal :quantity_out_of_range, add(quantity: 0).rejection
    assert_nil order
    assert_equal 0, Order.count
  end

  test "update_quantity enforces the same bounds and leaves the line unchanged when refused" do
    add(quantity: 2)
    line = order.order_items.sole
    [ 0, 21, -2 ].each do |q|
      assert_equal :quantity_out_of_range, OrderTaking.new(@call_log.reload).update_quantity(order_item_id: line.id, quantity: q).rejection
    end
    assert_equal 2, line.reload.quantity
    assert_not_predicate OrderTaking.new(@call_log.reload).update_quantity(order_item_id: line.id, quantity: 20), :rejected?
    assert_equal 20 * 1000, order.total_cents
  end

  # --- large orders ---

  test "30 items in total are accepted, the 31st is large_order_requires_staff" do
    add(quantity: 20)
    assert_not_predicate add(@fries, quantity: 10), :rejected?
    assert_equal 30, order.order_items.sum(:quantity)
    refused = add(@fries)
    assert_equal :large_order_requires_staff, refused.rejection
    assert_match(/transfer/, refused.message)
    assert_equal 30, order.order_items.sum(:quantity)
  end

  test "raising a line quantity past 30 items in total is refused; lowering it or removing frees room" do
    add(quantity: 20)
    add(@fries, quantity: 5)
    fries_line = order.order_items.find_by(menu_item: @fries)
    assert_equal :large_order_requires_staff, OrderTaking.new(@call_log.reload).update_quantity(order_item_id: fries_line.id, quantity: 11).rejection
    assert_not_predicate OrderTaking.new(@call_log.reload).update_quantity(order_item_id: fries_line.id, quantity: 10), :rejected?
  end

  # --- modifiers ---

  test "a modifier from another item or a missing id is invalid_modifier, listing the valid names, and nothing is written" do
    foreign = add(@burger, modifier_ids: [ @bacon.id ])
    assert_equal :invalid_modifier, foreign.rejection
    assert_includes foreign.message, "Cheese"
    assert_includes foreign.message, "Burger"

    missing = add(@burger, modifier_ids: [ @cheese.id, 0 ])
    assert_equal :invalid_modifier, missing.rejection
    assert_nil order
  end

  test "an item with no modifiers says so, and duplicate ids count once" do
    plain = @category.menu_items.create!(restaurant: @restaurant, name: "Water", price_cents: 100)
    assert_match(/has no modifiers/, add(plain, modifier_ids: [ @cheese.id ]).message)

    add(@burger, modifier_ids: [ @cheese.id, @cheese.id ])
    assert_equal [ { "name" => "Cheese", "price_cents" => 150 } ], order.order_items.sole.selected_modifiers
    assert_equal 1150, order.total_cents
  end

  # --- closed hours ---

  test "a closed restaurant refuses add and submit, reporting today's hours, and keeps the cart" do
    add
    @restaurant.update!(business_hours: %w[sun mon tue wed thu fri sat].index_with { "11:00-21:00" })
    zone = ActiveSupport::TimeZone[@restaurant.timezone]

    travel_to zone.local(2026, 9, 30, 23, 0) do
      refused = add(@fries)
      assert_equal :restaurant_closed, refused.rejection
      assert_includes refused.message, "11:00-21:00"
      assert_equal :restaurant_closed, OrderTaking.new(@call_log.reload).submit(fulfillment_type: "pickup").rejection
    end
    assert_equal 1, order.order_items.count
    assert_predicate order, :pending?

    travel_to zone.local(2026, 9, 30, 12, 0) do
      assert_not_predicate add(@fries), :rejected?
      assert_not_predicate OrderTaking.new(@call_log.reload).submit(fulfillment_type: "pickup"), :rejected?
    end
  end

  test "unconfigured hours count as closed" do
    @restaurant.update!(business_hours: {})
    assert_equal :restaurant_closed, add.rejection
  end

  # --- order state ---

  test "only a pending order accepts cart changes; submit is refused once the kitchen has it" do
    add
    OrderTaking.new(@call_log.reload).submit(fulfillment_type: "pickup")
    line = order.order_items.sole

    %i[confirmed preparing ready].each do |status|
      order.update!(status: status) unless order.status == status.to_s
      service = OrderTaking.new(@call_log.reload)
      assert_equal :order_already_submitted, service.add_item(menu_item_id: @fries.id).rejection, status
      assert_equal :order_already_submitted, service.update_quantity(order_item_id: line.id, quantity: 2).rejection, status
      assert_equal :order_already_submitted, service.remove_item(order_item_id: line.id).rejection, status
    end
    assert_equal :order_already_submitted, OrderTaking.new(@call_log.reload).submit(fulfillment_type: "pickup").rejection
    assert_equal [ 1, 1000 ], [ order.order_items.sole.quantity, order.total_cents ]
  end

  test "a cart abandoned at call end accepts no more changes" do
    add
    CallLifecycle.finish(external_call_id: @call_log.external_call_id, transcript: nil, recording_url: nil)
    assert_predicate order, :abandoned?
    assert_equal :order_already_submitted, add(@fries).rejection
  end

  # --- atomicity ---

  test "a failure after the order is created rolls back the order, the call link and the item" do
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { raise "boom" }
    begin
      assert_raises(RuntimeError) { add }
    ensure
      Order.define_method(:recompute_total!, original)
    end
    assert_nil order
    assert_equal [ 0, 0 ], [ Order.count, OrderItem.count ]
  end

  test "a failure on an existing cart rolls back that mutation only" do
    add
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { raise "boom" }
    begin
      assert_raises(RuntimeError) { add(@fries) }
    ensure
      Order.define_method(:recompute_total!, original)
    end
    assert_equal [ "Burger" ], order.order_items.map { |i| i.menu_item.name }
    assert_equal 1000, order.total_cents
  end
end

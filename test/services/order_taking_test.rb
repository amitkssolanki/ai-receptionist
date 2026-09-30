require "test_helper"

class OrderTakingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @restaurant = Restaurant.create!(name: "Svc Bistro", phone_number: "+15550003333", business_hours: ALWAYS_OPEN_HOURS)
    @item = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                       .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @cheese = @item.menu_item_modifiers.create!(name: "Cheese", price_cents: 150)
    customer = @restaurant.customers.create!(phone_number: "unknown-svc")
    @call_log = @restaurant.call_logs.create!(external_call_id: "svc_call", customer: customer, phone_number: "unknown-svc")
    @service = OrderTaking.new(@call_log)
  end

  test "read_back on an empty cart says so and records nothing" do
    result = @service.read_back
    assert_not_predicate result, :rejected?
    assert_equal({ items: [], total: 0.0, cart_version: 0, readback_text: "The cart is empty." }, result.payload)
  end

  test "add_item creates the order, links it to the call, prices modifiers and totals" do
    payload = @service.add_item(menu_item_id: @item.id, modifier_ids: [ @cheese.id ], quantity: 2, notes: "no onion").payload

    order = @call_log.reload.order
    assert_predicate order, :pending?
    assert_equal 2300, order.total_cents
    assert_equal 2300 / 100.0, payload[:total]
    assert_equal "no onion", order.order_items.sole.notes
    assert_equal [ { "name" => "Cheese", "price_cents" => 150 } ], order.order_items.sole.selected_modifiers
  end

  test "add_item defaults quantity to 1 and reuses the open order" do
    2.times { @service.add_item(menu_item_id: @item.id) }
    assert_equal [ 1, 1 ], @call_log.reload.order.order_items.map(&:quantity)
    assert_equal 1, Order.count
  end

  test "update_quantity and remove_item change the cart and total" do
    @service.add_item(menu_item_id: @item.id)
    line = @call_log.reload.order.order_items.sole

    @service.update_quantity(order_item_id: line.id, quantity: 3)
    assert_equal 3000, @call_log.order.reload.total_cents
    @service.remove_item(order_item_id: line.id)
    assert_equal 0, @call_log.order.reload.total_cents
  end

  test "submit on an empty cart is a cart_empty rejection, not an exception" do
    result = @service.submit(fulfillment_type: "pickup", cart_version: 0)
    assert_predicate result, :rejected?
    assert_equal :cart_empty, result.rejection
    assert_equal OrderTaking::MESSAGES[:cart_empty], result.message
  end

  test "submit confirms the order, stamps placed_at and enqueues the SMS" do
    @service.add_item(menu_item_id: @item.id)
    assert_enqueued_jobs 1, only: OrderConfirmationSmsJob do
      @service.read_back
      result = @service.submit(fulfillment_type: "delivery", cart_version: 1, delivery_address: "1 Main St", notes: "ring twice")
      assert_not_predicate result, :rejected?
    end

    order = @call_log.reload.order
    assert_predicate order, :confirmed?
    assert_predicate order.placed_at, :present?
    assert_equal [ "delivery", "1 Main St", "ring twice" ], [ order.fulfillment_type, order.delivery_address, order.notes ]
  end

  test "unknown items, missing cart lines and delivery without an address are refusals, not exceptions" do
    assert_equal :menu_item_unavailable, @service.add_item(menu_item_id: 0).rejection
    assert_equal :cart_empty, @service.update_quantity(order_item_id: 1, quantity: 2).rejection
    assert_equal :cart_empty, @service.remove_item(order_item_id: 1).rejection

    @service.add_item(menu_item_id: @item.id)
    assert_equal :item_not_in_cart, @service.remove_item(order_item_id: 0).rejection
    assert_equal :delivery_address_required, @service.submit(fulfillment_type: "delivery", cart_version: 1).rejection
    assert_predicate @call_log.reload.order, :pending?
  end
end

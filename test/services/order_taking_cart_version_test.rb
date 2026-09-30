require "test_helper"

# Step 5: the server owns which cart version is current and which version the caller heard read back.
class OrderTakingCartVersionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @restaurant = Restaurant.create!(name: "Version Bistro", phone_number: "+15550001212", business_hours: ALWAYS_OPEN_HOURS)
    category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @cheese = @burger.menu_item_modifiers.create!(name: "Extra cheese", price_cents: 150)
    @fries = category.menu_items.create!(restaurant: @restaurant, name: "Fries", price_cents: 400)
    customer = @restaurant.customers.create!(phone_number: "unknown-version")
    @call_log = @restaurant.call_logs.create!(external_call_id: "version_call", customer: customer, phone_number: "unknown-version")
  end

  def svc = OrderTaking.new(@call_log.reload)
  def order = @call_log.reload.order
  def add(item = @burger, **opts) = svc.add_item(menu_item_id: item.id, **opts)
  def read_back = svc.read_back
  def submit(version, **opts) = svc.submit(fulfillment_type: "pickup", cart_version: version, **opts)

  test "1. every authoritative cart mutation increments the version by exactly one; reads never do" do
    assert_equal 0, read_back.payload[:cart_version]
    assert_equal 1, add.payload[:cart_version]
    assert_equal 2, add(@fries).payload[:cart_version]
    line = order.order_items.first
    assert_equal 3, svc.update_quantity(order_item_id: line.id, quantity: 2).payload[:cart_version]
    assert_equal 4, svc.remove_item(order_item_id: line.id).payload[:cart_version]

    3.times { read_back }
    assert_equal 4, order.cart_version
  end

  test "2. read-back reflects the current version and records it as the version read back" do
    add(@burger, modifier_ids: [ @cheese.id ])
    add(@fries, quantity: 2)

    payload = read_back.payload
    assert_equal 2, payload[:cart_version]
    assert_equal "One Burger with extra cheese and two Fries. Total nineteen dollars and fifty cents.", payload[:readback_text]
    assert_equal [ 2, true ], [ order.read_back_version, order.read_back_at.present? ]
  end

  test "3. a mutation after the read-back makes that read-back stale" do
    add
    read_back
    assert_equal order.cart_version, order.read_back_version

    add(@fries)
    assert_operator order.read_back_version, :<, order.cart_version
  end

  test "4. submitting a stale version is refused with the current version, and nothing is confirmed" do
    add
    read_back # v1
    add(@fries) # v2

    refused = submit(1)
    assert_equal :cart_changed_since_readback, refused.rejection
    assert_equal({ cart_version: 2 }, refused.details)
    assert_match(/cart_version is 2/, refused.message)
    assert_predicate order, :pending?
    assert_equal 0, enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }

    # Quoting the new version without reading it back is still refused: the read-back itself is stale.
    assert_equal :cart_changed_since_readback, submit(2).rejection
  end

  test "submitting with no read-back at all is readback_required" do
    add
    assert_equal :readback_required, submit(1).rejection
    assert_predicate order, :pending?
  end

  test "a read-back at the current version but a wrong version argument is refused" do
    add
    read_back
    assert_equal :cart_changed_since_readback, submit(0).rejection
    assert_equal :cart_changed_since_readback, submit(7).rejection
  end

  test "5. submitting the current, read-back version succeeds" do
    add
    add(@fries)
    read_back

    assert_enqueued_jobs 1, only: OrderConfirmationSmsJob do
      result = submit(2, notes: "thanks")
      assert_not_predicate result, :rejected?
      assert_equal 2, result.payload[:cart_version]
    end
    assert_predicate order, :confirmed?
  end

  test "re-reading back after a change makes the new version submittable" do
    add
    read_back
    add(@fries)
    assert_equal :cart_changed_since_readback, submit(2).rejection
    read_back
    assert_not_predicate submit(2), :rejected?
  end

  test "6. refused and failed mutations do not advance the version" do
    add
    before = order.cart_version

    assert_equal :menu_item_unavailable, svc.add_item(menu_item_id: 0).rejection
    assert_equal :quantity_out_of_range, add(@fries, quantity: 99).rejection
    assert_equal :invalid_modifier, add(@fries, modifier_ids: [ @cheese.id ]).rejection
    assert_equal :item_not_in_cart, svc.remove_item(order_item_id: 0).rejection
    assert_equal :quantity_out_of_range, svc.update_quantity(order_item_id: order.order_items.first.id, quantity: 0).rejection
    assert_equal before, order.cart_version

    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { |*, **| raise "boom" }
    begin
      assert_raises(RuntimeError) { add(@fries) }
    ensure
      Order.define_method(:recompute_total!, original)
    end
    assert_equal before, order.cart_version
    assert_equal 1, order.order_items.count
  end

  test "a read-back of an empty cart or a finished order is not recorded" do
    read_back
    assert_nil order

    add
    read_back
    submit(1)
    placed = order.read_back_at
    travel(1.minute) { read_back }
    assert_equal placed, order.reload.read_back_at
  end

  test "confirmation_text states each change in words, from the server's state" do
    added = add(@burger, modifier_ids: [ @cheese.id ], quantity: 2).payload[:confirmation_text]
    assert_equal "Added two Burger with extra cheese. The total is now twenty-three dollars.", added

    line = order.order_items.sole
    assert_equal "Changed Burger to three. The total is now thirty-four dollars and fifty cents.",
                 svc.update_quantity(order_item_id: line.id, quantity: 3).payload[:confirmation_text]
    assert_equal "Removed Burger. The cart is now empty.", svc.remove_item(order_item_id: line.id).payload[:confirmation_text]
  end

  test "an empty cart's read-back text says so" do
    assert_equal "The cart is empty.", read_back.payload[:readback_text]
  end
end

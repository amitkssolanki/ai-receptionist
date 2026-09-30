require "test_helper"

# Step 7: one authoritative execution per (call, toolCallId); a redelivery returns the stored result and changes nothing.
class Voice::ToolIdempotencyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @restaurant = Restaurant.create!(name: "Idem Bistro", phone_number: "+15550005656", business_hours: ALWAYS_OPEN_HOURS)
    category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @fries = category.menu_items.create!(restaurant: @restaurant, name: "Fries", price_cents: 400)
    @call_log = CallLifecycle.start(external_call_id: "idem_1", dialed_number: @restaurant.phone_number, caller_number: "+15557770101") # a real number: SMS-capable
  end

  def run_tool(id, name, arguments = {}, timestamp: nil)
    Voice::ToolRunner.call(
      call_log: CallLog.find(@call_log.id),
      tool_call: { "id" => id, "function" => { "name" => name, "arguments" => arguments } },
      vapi_timestamp: timestamp
    )
  end

  def order = @call_log.reload.order
  def row(id) = @call_log.tool_invocations.find_by!(tool_call_id: id)
  def sms_jobs = enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }

  # --- basics ---

  test "first delivery executes; a duplicate returns the same stored result and counts as a replay" do
    first = run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id })
    second = run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id })
    third = run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id })

    assert_equal first, second
    assert_equal first, third
    assert_equal 1, order.order_items.count
    assert_equal 1, @call_log.tool_invocations.count
    assert_equal 2, row("a1").replay_count
    assert_equal first, row("a1").result
  end

  test "a replay is answered from the stored row even if the duplicate's arguments differ" do
    first = run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id })
    assert_equal first, run_tool("a1", "add_to_cart", { "menu_item_id" => @fries.id, "quantity" => 5 })
    assert_equal [ "Burger" ], order.order_items.map { |i| i.menu_item.name }
  end

  test "the same toolCallId on a different call is a different tool call" do
    other = CallLifecycle.start(external_call_id: "idem_2", dialed_number: @restaurant.phone_number, caller_number: nil)
    run_tool("shared", "add_to_cart", { "menu_item_id" => @burger.id })
    Voice::ToolRunner.call(call_log: other, tool_call: { "id" => "shared", "function" => { "name" => "add_to_cart", "arguments" => { "menu_item_id" => @fries.id } } })

    assert_equal [ 1, 1 ], [ @call_log.tool_invocations.count, other.tool_invocations.count ]
    assert_equal 2, Order.count
  end

  # --- mutations ---

  test "a duplicate add does not add twice" do
    2.times { run_tool("add", "add_to_cart", { "menu_item_id" => @burger.id, "quantity" => 2 }) }
    assert_equal [ 2, 1 ], [ order.order_items.sum(:quantity), order.cart_version ]
  end

  test "a duplicate update does not update twice" do
    run_tool("add", "add_to_cart", { "menu_item_id" => @burger.id })
    line = order.order_items.sole
    first = run_tool("upd", "update_cart_item_quantity", { "order_item_id" => line.id, "quantity" => 3 })
    order.update_columns(total_cents: 1) # prove the duplicate does not touch the order at all
    assert_equal first, run_tool("upd", "update_cart_item_quantity", { "order_item_id" => line.id, "quantity" => 3 })
    assert_equal [ 3, 2, 1 ], [ line.reload.quantity, order.cart_version, order.total_cents ]
  end

  test "a duplicate remove does not remove twice (and does not fail because the line is already gone)" do
    run_tool("add1", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("add2", "add_to_cart", { "menu_item_id" => @fries.id })
    line = order.order_items.find_by(menu_item: @burger)
    first = run_tool("rm", "remove_cart_item", { "order_item_id" => line.id })
    assert_equal first, run_tool("rm", "remove_cart_item", { "order_item_id" => line.id })

    assert_equal 1, JSON.parse(first)["items"].size
    assert_equal [ "Fries" ], order.order_items.map { |i| i.menu_item.name }
    assert_equal 3, order.cart_version
  end

  test "a duplicate submit does not submit twice: same result, same placed_at, one SMS" do
    run_tool("add", "add_to_cart", { "menu_item_id" => @burger.id })
    version = JSON.parse(run_tool("cart", "get_cart"))["cart_version"]

    result = nil
    assert_enqueued_jobs 1, only: OrderConfirmationSmsJob do
      result = run_tool("sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => version })
      travel(1.minute) do
        assert_equal result, run_tool("sub", "submit_order", { "fulfillment_type" => "delivery", "cart_version" => version, "delivery_address" => "1 Main St" })
      end
    end
    placed = order.placed_at
    assert_predicate order, :confirmed?
    assert_predicate order, :pickup?, "the duplicate must not switch fulfillment"
    assert_equal 1, sms_jobs
    assert_equal 1, row("sub").replay_count
    assert_equal placed, order.reload.placed_at
  end

  test "a duplicate of a refusal returns the stored refusal, even if the state would now allow it" do
    run_tool("add", "add_to_cart", { "menu_item_id" => @burger.id })
    refused = run_tool("sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })
    assert_equal "readback_required", JSON.parse(refused).dig("error", "code")

    run_tool("cart", "get_cart") # now a submit would succeed...
    assert_equal refused, run_tool("sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) # ...but this delivery is the old one
    assert_predicate order, :pending?
    assert_equal 0, sms_jobs
  end

  test "a duplicate of a stored internal_error is replayed, not retried" do
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { |*, **| raise "boom" }
    begin
      failed = run_tool("boom", "add_to_cart", { "menu_item_id" => @burger.id })
    ensure
      Order.define_method(:recompute_total!, original)
    end

    assert_equal "internal_error", JSON.parse(failed).dig("error", "code")
    assert_equal failed, run_tool("boom", "add_to_cart", { "menu_item_id" => @burger.id })
    assert_nil order
    assert_equal [ "error", 1 ], [ row("boom").status, row("boom").replay_count ]
  end

  # --- read-back ---

  test "a late duplicate get_cart cannot make a stale read-back current" do
    run_tool("add1", "add_to_cart", { "menu_item_id" => @burger.id })
    original = JSON.parse(run_tool("cartA", "get_cart")) # read back at v1
    assert_equal [ 1, 1 ], [ original["cart_version"], order.read_back_version ]
    read_back_at = order.read_back_at

    run_tool("add2", "add_to_cart", { "menu_item_id" => @fries.id }) # cart is now v2
    assert_equal 2, order.cart_version

    travel(1.minute) do
      duplicate = JSON.parse(run_tool("cartA", "get_cart")) # late duplicate of the first read-back
      assert_equal original, duplicate, "the stored original result, not a fresh read-back"
    end
    assert_equal [ 2, 1, read_back_at ], [ order.cart_version, order.read_back_version, order.read_back_at ], "read-back untouched"

    stale = JSON.parse(run_tool("sub1", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }))
    assert_equal "cart_changed_since_readback", stale.dig("error", "code")
    assert_equal 2, stale.dig("error", "cart_version")
    quoted_new = JSON.parse(run_tool("sub2", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 }))
    assert_equal "cart_changed_since_readback", quoted_new.dig("error", "code")
    assert_predicate order, :pending?
    assert_equal 0, sms_jobs

    # A genuinely new get_cart is what makes v2 submittable.
    fresh = JSON.parse(run_tool("cartB", "get_cart"))
    assert_equal 2, fresh["cart_version"]
    assert_nil JSON.parse(run_tool("sub3", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 }))["error"]
  end

  # --- cart versions on the audit row ---

  test "ToolInvocation records the cart version before and after every call" do
    run_tool("g0", "get_cart")
    run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("g1", "get_cart")
    run_tool("bad", "add_to_cart", { "menu_item_id" => @fries.id, "quantity" => 99 }) # refused
    run_tool("a2", "add_to_cart", { "menu_item_id" => @fries.id })
    line = order.order_items.find_by(menu_item: @burger)
    run_tool("u", "update_cart_item_quantity", { "order_item_id" => line.id, "quantity" => 2 })
    run_tool("r", "remove_cart_item", { "order_item_id" => line.id })
    run_tool("menu", "get_menu")

    versions = %w[g0 a1 g1 bad a2 u r menu].to_h { |id| [ id, [ row(id).cart_version_before, row(id).cart_version_after ] ] }
    assert_equal(
      { "g0" => [ 0, 0 ], "a1" => [ 0, 1 ], "g1" => [ 1, 1 ], "bad" => [ 1, 1 ], "a2" => [ 1, 2 ],
        "u" => [ 2, 3 ], "r" => [ 3, 4 ], "menu" => [ 4, 4 ] },
      versions
    )
    assert_equal "rejected", row("bad").status
  end

  test "a failed mutation records before == after (its writes were rolled back)" do
    run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id })
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { |*, **| raise "boom" }
    begin
      run_tool("boom", "add_to_cart", { "menu_item_id" => @fries.id })
    ensure
      Order.define_method(:recompute_total!, original)
    end
    assert_equal [ "error", 1, 1 ], [ row("boom").status, row("boom").cart_version_before, row("boom").cart_version_after ]
    assert_equal 1, order.order_items.count, "the half-written item was rolled back"
    assert_equal 1, order.cart_version
  end

  test "a duplicate keeps the original before/after and does not rewrite the row" do
    run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id })
    original = row("a1").attributes.except("replay_count", "updated_at")
    run_tool("a2", "add_to_cart", { "menu_item_id" => @fries.id })
    3.times { run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id }) }

    assert_equal original, row("a1").attributes.except("replay_count", "updated_at")
    assert_equal [ 0, 1, 3 ], [ row("a1").cart_version_before, row("a1").cart_version_after, row("a1").replay_count ]
    assert_equal 2, order.cart_version
  end

  # --- transactionality ---

  test "if the audit row cannot be written the business change is rolled back with it, then applied exactly once unrecorded" do
    original = ToolInvocation.method(:record!)
    ToolInvocation.define_singleton_method(:record!) { |**| raise ActiveRecord::StatementInvalid, "audit table unavailable" }
    begin
      result = run_tool("a1", "add_to_cart", { "menu_item_id" => @burger.id })
    ensure
      ToolInvocation.define_singleton_method(:record!, original)
    end

    assert_equal true, JSON.parse(result)["ok"], "the model response is unchanged"
    assert_equal 1, order.order_items.count, "applied once, not twice"
    assert_equal 1, order.cart_version
    assert_equal 0, @call_log.tool_invocations.count
  end

  test "no ToolInvocation is written for a business change that rolled back, and no item survives an error" do
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { |*, **| raise "boom" }
    begin
      run_tool("boom", "add_to_cart", { "menu_item_id" => @burger.id })
    ensure
      Order.define_method(:recompute_total!, original)
    end
    assert_equal [ 0, 0, "error" ], [ Order.count, OrderItem.count, row("boom").status ]
  end

  # --- timestamps (regression guard for the Steps 0-2 finding) ---

  test "every supported timestamp form is persisted; an invalid one never prevents the row" do
    { "t_int" => 1_790_000_000_123, "t_float" => 1_790_000_000_123.0, "t_str" => "1790000000123" }.each do |id, ts|
      run_tool(id, "get_cart", {}, timestamp: ts)
      assert_equal Time.zone.at(1_790_000_000, 123, :millisecond), row(id).vapi_requested_at, id
    end
    [ nil, "garbage", {}, [], -5 ].each_with_index do |ts, i|
      run_tool("t_bad#{i}", "get_cart", {}, timestamp: ts)
      assert row("t_bad#{i}"), "row persisted for #{ts.inspect}"
    end
    assert_nil row("t_bad1").vapi_requested_at
  end
end

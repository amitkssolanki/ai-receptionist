require "test_helper"

# Regression for live call #10: when the audit row cannot be written, the business change rolls back and the tool is
# served once, unrecorded. On a call's first add_to_cart the rollback left the in-memory CallLog holding the rolled-back
# order_id, and the fallback's lock! raised "Locking a record with unpersisted changes", so the caller got an error and
# no order. The transactional test wrapper hides this (its BEGIN/ROLLBACK become savepoints), so this test runs with
# real top-level transactions and cleans up only what it created.
class Voice::ToolRunnerUnrecordedFallbackTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @restaurant = Restaurant.create!(name: "Fallback Pizzeria", phone_number: "+15550007070", business_hours: ALWAYS_OPEN_HOURS)
    @pizza = @restaurant.menu_categories.create!(name: "Pizzas", position: 1)
                        .menu_items.create!(restaurant: @restaurant, name: "Margherita Pizza", price_cents: 1400)
    @call_log = CallLifecycle.start(external_call_id: "fallback_#{SecureRandom.hex(4)}", dialed_number: @restaurant.phone_number, caller_number: nil)
  end

  teardown do
    call_ids = CallLog.where(restaurant: @restaurant).ids
    order_ids = Order.where(restaurant: @restaurant).ids
    ToolInvocation.where(call_log_id: call_ids).delete_all
    OrderItem.where(order_id: order_ids).delete_all
    CallLog.where(id: call_ids).delete_all
    Order.where(id: order_ids).delete_all
    Customer.where(restaurant: @restaurant).delete_all
    MenuItem.where(restaurant: @restaurant).delete_all
    MenuCategory.where(restaurant: @restaurant).delete_all
    @restaurant.delete
  end

  def run_tool(id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(@call_log.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } })
  end

  # The audit insert fails inside create! on an attribute the model does not know - the live error (a server whose
  # column information predated the turn_evidence migration raised ActiveModel::UnknownAttributeError there).
  def with_audit_insert_failing
    original = ToolInvocation.method(:record!)
    ToolInvocation.define_singleton_method(:record!) { |call_log:, **| ToolInvocation.create!(call_log: call_log, column_the_model_does_not_know: 1) }
    yield
  ensure
    ToolInvocation.define_singleton_method(:record!, original)
  end

  test "the first add_to_cart is served unrecorded after a real rollback, with its normal result" do
    assert_equal 0, ApplicationRecord.connection.open_transactions, "must run outside any wrapping transaction"

    result = nil
    with_audit_insert_failing do
      assert_nothing_raised { result = run_tool("a1", "add_to_cart", { "menu_item_id" => @pizza.id }) }
    end

    body = JSON.parse(result)
    assert_equal true, body["ok"], "the model gets the normal business result, not an error"
    assert_equal [ [ "Margherita Pizza", 1 ] ], body["items"].map { |i| [ i["menu_item"], i["quantity"] ] }
    assert_equal [ 14.0, 1 ], body.values_at("total", "cart_version")

    order = CallLog.find(@call_log.id).order
    assert order, "the order is persisted and linked to the call"
    assert_equal [ 1, 1, 1400 ], [ order.order_items.count, order.cart_version, order.total_cents ], "applied exactly once"
    assert_equal 1, Order.where(restaurant: @restaurant).count, "no orphan from the rolled-back attempt"
    assert_equal 0, ToolInvocation.where(call_log_id: @call_log.id).count, "the fallback stays unrecorded"
  end

  # The same stale-state hazard on the other rolled-back path: a unique-index conflict on the audit row makes the runner
  # retry the whole transaction, which must also start from the persisted call row.
  test "a retry after a unique-index conflict on the first add_to_cart also starts from persisted state" do
    original = ToolInvocation.method(:record!)
    conflicts = 0
    ToolInvocation.define_singleton_method(:record!) do |**kw|
      conflicts += 1
      raise ActiveRecord::RecordNotUnique, "simulated concurrent insert" if conflicts == 1
      original.call(**kw)
    end
    begin
      result = nil
      assert_nothing_raised { result = run_tool("a1", "add_to_cart", { "menu_item_id" => @pizza.id }) }
      assert_equal [ true, 1 ], JSON.parse(result).values_at("ok", "cart_version")
    ensure
      ToolInvocation.define_singleton_method(:record!, original)
    end

    assert_equal 2, conflicts, "retried once"
    order = CallLog.find(@call_log.id).order
    assert_equal [ 1, 1 ], [ order.order_items.count, order.cart_version ], "applied exactly once"
    assert_equal [ "a1" ], ToolInvocation.where(call_log_id: @call_log.id).pluck(:tool_call_id), "recorded by the retry"
  end

  test "after the unrecorded fallback, later tool calls see the persisted order and are recorded normally" do
    with_audit_insert_failing { run_tool("a1", "add_to_cart", { "menu_item_id" => @pizza.id }) }
    cart = JSON.parse(run_tool("c1", "get_cart"))

    assert_equal [ true, 1, 14.0 ], cart.values_at("ok", "cart_version", "total")
    assert_equal [ "get_cart" ], ToolInvocation.where(call_log_id: @call_log.id).pluck(:tool_name)
  end
end

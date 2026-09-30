require "test_helper"

class Voice::ToolRunnerTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(name: "Runner Bistro", phone_number: "+15550007777")
    @item = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                       .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @call_log = CallLifecycle.start(external_call_id: "runner_1", dialed_number: @restaurant.phone_number, caller_number: nil)
  end

  def run_tool(name, arguments = {}, id: "tc_#{SecureRandom.hex(3)}", call_log: @call_log)
    Voice::ToolRunner.call(call_log: call_log, tool_call: { "id" => id, "function" => { "name" => name, "arguments" => arguments } })
  end

  test "dispatches each tool to its service and returns JSON strings" do
    assert_equal "Burger", JSON.parse(run_tool("get_menu")).dig(0, "items", 0, "name")
    assert_equal 10.0, JSON.parse(run_tool("add_to_cart", { "menu_item_id" => @item.id }))["total"]
    assert_equal 10.0, JSON.parse(run_tool("get_cart"))["total"]

    line = @call_log.reload.order.order_items.sole
    assert_equal 30.0, JSON.parse(run_tool("update_cart_item_quantity", { "order_item_id" => line.id, "quantity" => 3 }))["total"]
    assert_equal 0.0, JSON.parse(run_tool("remove_cart_item", { "order_item_id" => line.id }))["total"]
  end

  test "submit_order confirms; transfer_to_human replies in plain text" do
    run_tool("add_to_cart", { "menu_item_id" => @item.id })
    assert_equal 10.0, JSON.parse(run_tool("submit_order", { "fulfillment_type" => "pickup" }))["total"]
    assert_predicate @call_log.reload.order, :confirmed?

    assert_equal "Transfer logged.", run_tool("transfer_to_human", { "reason" => "complaint" })
    assert_predicate @call_log.reload, :transferred?
  end

  test "fixed replies for no call, unknown tools, and contained failures" do
    assert_equal "No active call found for this request.", run_tool("get_cart", call_log: nil)
    assert_equal "Unknown tool: nope", run_tool("nope")
    assert_match(/\ASorry, something went wrong handling that - key not found: "menu_item_id"/, run_tool("add_to_cart"))
  end

  test "each execution is recorded with status and code" do
    run_tool("add_to_cart", { "menu_item_id" => @item.id })
    run_tool("submit_order", { "fulfillment_type" => "pickup" }, id: "tc_ok")
    run_tool("nope", id: "tc_unknown")
    run_tool("add_to_cart", {}, id: "tc_err")

    rows = @call_log.tool_invocations.index_by(&:tool_call_id)
    assert_equal 4, rows.size
    assert_equal "ok", rows["tc_ok"].status
    assert_equal [ "rejected", "unknown_tool" ], [ rows["tc_unknown"].status, rows["tc_unknown"].error_code ]
    assert_equal [ "error", "KeyError" ], [ rows["tc_err"].status, rows["tc_err"].error_class ]
  end
end

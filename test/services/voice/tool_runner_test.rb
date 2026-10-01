require "test_helper"

class Voice::ToolRunnerTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(name: "Runner Bistro", phone_number: "+15550007777", business_hours: ALWAYS_OPEN_HOURS)
    @item = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                       .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @call_log = CallLifecycle.start(external_call_id: "runner_1", dialed_number: @restaurant.phone_number, caller_number: nil)
  end

  # submit_order carries a history in which the caller answered the read-back (the confirmation gate's input, see
  # VapiHistory); the gate itself is tested in test/controllers/api/vapi/confirmation_gate_test.rb.
  def run_tool(name, arguments = {}, id: "tc_#{SecureRandom.hex(3)}", call_log: @call_log)
    Voice::ToolRunner.call(call_log: call_log, tool_call: { "id" => id, "function" => { "name" => name, "arguments" => arguments } },
                           artifact: VapiHistory.for_tool(name, id))
  end

  test "dispatches each tool to its service and returns JSON strings" do
    assert_equal "Burger", JSON.parse(run_tool("get_menu")).dig("categories", 0, "items", 0, "name")
    assert_equal 10.0, JSON.parse(run_tool("add_to_cart", { "menu_item_id" => @item.id }))["total"]
    assert_equal 10.0, JSON.parse(run_tool("get_cart"))["total"]

    line = @call_log.reload.order.order_items.sole
    assert_equal 30.0, JSON.parse(run_tool("update_cart_item_quantity", { "order_item_id" => line.id, "quantity" => 3 }))["total"]
    assert_equal 0.0, JSON.parse(run_tool("remove_cart_item", { "order_item_id" => line.id }))["total"]
  end

  test "submit_order confirms; transfer_to_human acknowledges" do
    run_tool("add_to_cart", { "menu_item_id" => @item.id })
    version = JSON.parse(run_tool("get_cart"))["cart_version"]
    assert_equal 10.0, JSON.parse(run_tool("submit_order", { "fulfillment_type" => "pickup", "cart_version" => version }))["total"]
    assert_predicate @call_log.reload.order, :confirmed?

    assert_equal({ "ok" => true, "message" => "Transfer logged." }, JSON.parse(run_tool("transfer_to_human", { "reason" => "complaint" })))
    assert_predicate @call_log.reload, :transferred?
  end

  test "fixed replies for no call, unknown tools, and contained failures" do
    assert_equal "no_active_call", JSON.parse(run_tool("get_cart", call_log: nil)).dig("error", "code")
    assert_equal "unknown_tool", JSON.parse(run_tool("nope")).dig("error", "code")
    assert_equal "invalid_arguments", JSON.parse(run_tool("add_to_cart")).dig("error", "code")
  end

  test "each execution is recorded with status and code" do
    run_tool("add_to_cart", { "menu_item_id" => @item.id })
    version = JSON.parse(run_tool("get_cart"))["cart_version"]
    run_tool("submit_order", { "fulfillment_type" => "pickup", "cart_version" => version }, id: "tc_ok")
    run_tool("nope", id: "tc_unknown")
    run_tool("add_to_cart", {}, id: "tc_err")

    rows = @call_log.tool_invocations.index_by(&:tool_call_id)
    assert_equal 5, rows.size
    assert_equal "ok", rows["tc_ok"].status
    assert_equal [ "rejected", "unknown_tool" ], [ rows["tc_unknown"].status, rows["tc_unknown"].error_code ]
    assert_equal [ "rejected", "invalid_arguments" ], [ rows["tc_err"].status, rows["tc_err"].error_code ]
  end

  test "no tool response ever contains exception text, SQL or class names" do
    LEAK = /ActiveRecord|NoMethodError|KeyError|TypeError|undefined method|key not found|Validation failed|Couldn't find|SELECT |\.rb:\d+|Sorry, something went wrong/
    battery = [
      [ "add_to_cart", {} ], [ "add_to_cart", "{not json" ], [ "add_to_cart", "[1]" ], [ "add_to_cart", { "menu_item_id" => "x" } ],
      [ "add_to_cart", { "menu_item_id" => 0 } ], [ "add_to_cart", { "menu_item_id" => @item.id, "quantity" => 0 } ],
      [ "add_to_cart", { "menu_item_id" => @item.id, "quantity" => -3 } ], [ "add_to_cart", { "menu_item_id" => @item.id, "modifier_ids" => "a" } ],
      [ "update_cart_item_quantity", { "order_item_id" => 1, "quantity" => 2 } ], [ "remove_cart_item", { "order_item_id" => 1 } ],
      [ "submit_order", {} ], [ "submit_order", { "fulfillment_type" => "teleport" } ],
      [ "submit_order", { "fulfillment_type" => "delivery", "cart_version" => 1 } ], [ "transfer_to_human", { "reason" => 5 } ],
      [ "nope", {} ], [ nil, {} ]
    ]
    battery.each_with_index do |(name, args), i|
      result = run_tool(name, args, id: "leak_#{i}")
      assert_no_match LEAK, result, "#{name} #{args.inspect}"
      assert_equal false, JSON.parse(result)["ok"], "#{name} #{args.inspect} should be refused"
    end
    # Even a call with no (or a nonsense) tool name is audited rather than silently dropped.
    assert_equal battery.size, @call_log.tool_invocations.where("tool_call_id LIKE 'leak_%'").count
    assert_equal "(none)", @call_log.tool_invocations.find_by!(tool_call_id: "leak_#{battery.size - 1}").tool_name
  end

  test "a model validation that slips past the rules becomes invalid_arguments naming fields, not exception text" do
    record = OrderItem.new.tap { |r| r.errors.add(:quantity, "secret model message") }
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { |*, **| raise ActiveRecord::RecordInvalid, record }
    begin
      result = run_tool("add_to_cart", { "menu_item_id" => @item.id })
    ensure
      Order.define_method(:recompute_total!, original)
    end

    error = JSON.parse(result)["error"]
    assert_equal "invalid_arguments", error["code"]
    assert_match(/check quantity/, error["message"])
    assert_no_match(/secret model message|RecordInvalid/, result)
    assert_nil @call_log.reload.order, "rolled back"
  end

  test "vapi_requested_at is stored for integer, float and numeric-string timestamps, and a bad one never drops the row" do
    { "ts_int" => 1_790_000_000_123, "ts_float" => 1_790_000_000_123.0, "ts_str" => "1790000000123" }.each do |id, ts|
      Voice::ToolRunner.call(call_log: @call_log, tool_call: { "id" => id, "function" => { "name" => "get_cart", "arguments" => {} } }, vapi_timestamp: ts)
    end
    %w[ts_int ts_float ts_str].each do |id|
      row = @call_log.tool_invocations.find_by!(tool_call_id: id)
      assert_equal Time.zone.at(1_790_000_000, 123, :millisecond), row.vapi_requested_at, id
    end

    [ nil, "garbage", {}, [] ].each_with_index do |ts, i|
      Voice::ToolRunner.call(call_log: @call_log, tool_call: { "id" => "ts_bad_#{i}", "function" => { "name" => "get_cart", "arguments" => {} } }, vapi_timestamp: ts)
      row = @call_log.tool_invocations.find_by(tool_call_id: "ts_bad_#{i}")
      assert row, "row must be persisted for timestamp #{ts.inspect}"
      assert_nil row.vapi_requested_at
    end
  end

  test "get_menu_item returns one item's detail, and a menu_item_unavailable refusal for anything else" do
    modifier = @item.menu_item_modifiers.create!(name: "Extra cheese", price_cents: 150)

    detail = JSON.parse(run_tool("get_menu_item", { "menu_item_id" => @item.id }))
    assert_equal true, detail["ok"]
    assert_equal [ "Burger", [ modifier.id ] ], [ detail["name"], detail["modifiers"].map { |m| m["id"] } ]

    assert_equal "menu_item_unavailable", JSON.parse(run_tool("get_menu_item", { "menu_item_id" => 0 })).dig("error", "code")
    assert_equal "invalid_arguments", JSON.parse(run_tool("get_menu_item", {})).dig("error", "code")
  end

  test "add_to_cart offers the item's available pairings" do
    sides = @restaurant.menu_categories.create!(name: "Sides", position: 2)
    fries = sides.menu_items.create!(restaurant: @restaurant, name: "Fries", price_cents: 400)
    gone = sides.menu_items.create!(restaurant: @restaurant, name: "Gone", price_cents: 400, available: false)
    @item.menu_item_upsells.create!(upsell_item: fries)
    @item.menu_item_upsells.create!(upsell_item: gone)

    result = JSON.parse(run_tool("add_to_cart", { "menu_item_id" => @item.id }))
    assert_equal [ { "id" => fries.id, "name" => "Fries", "price" => 4.0 } ], result["suggest_with"]
  end
end

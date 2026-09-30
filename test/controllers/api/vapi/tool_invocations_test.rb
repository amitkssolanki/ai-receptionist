require "test_helper"

# Phase 1 / Step 1: every server-side tool execution on the Vapi path leaves a tool_invocations row, and recording
# never alters what the model is told.
class Api::Vapi::ToolInvocationsTest < ActionDispatch::IntegrationTest
  setup do
    ENV["VAPI_SERVER_SECRET"] = "test-vapi-secret"
    @restaurant = Restaurant.create!(name: "Test Bistro", phone_number: "+15550001111", business_hours: ALWAYS_OPEN_HOURS)
    @item = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                       .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    vapi(type: "status-update", status: "in-progress", call: { id: "call_ti", type: "webCall" })
    @call_log = CallLog.find_by!(external_call_id: "call_ti")
  end

  teardown { ENV.delete("VAPI_SERVER_SECRET") }

  def vapi(message)
    post api_vapi_webhooks_path, params: { message: message }, headers: { "X-Vapi-Secret" => "test-vapi-secret" }, as: :json
  end

  def tool(name, arguments = {}, id: "tc_#{SecureRandom.hex(3)}", call: "call_ti", timestamp: nil)
    message = { type: "tool-calls", call: { id: call }, toolCallList: [ { id: id, function: { name: name, arguments: arguments } } ] }
    message[:timestamp] = timestamp if timestamp
    vapi(message)
    JSON.parse(response.body)["results"].first["result"]
  end

  test "a successful tool records arguments, the exact result, timing and the touched order" do
    result = tool("add_to_cart", { menu_item_id: @item.id, quantity: 2 }, id: "tc_add", timestamp: 1_790_000_000_123)

    invocation = @call_log.tool_invocations.sole
    assert_equal "tc_add", invocation.tool_call_id
    assert_equal "add_to_cart", invocation.tool_name
    assert_equal({ "menu_item_id" => @item.id, "quantity" => 2 }, invocation.arguments)
    assert_equal result, invocation.result
    assert_predicate invocation, :ok?
    assert_predicate invocation, :vapi?
    assert_nil invocation.error_code
    assert_equal @call_log.reload.order, invocation.order
    assert_operator invocation.duration_ms, :>=, 0
    assert_operator invocation.finished_at, :>=, invocation.started_at
    assert_equal Time.zone.at(1_790_000_000, 123, :millisecond), invocation.vapi_requested_at
    assert_nil invocation.cart_version_before
  end

  test "string arguments are stored parsed" do
    tool("add_to_cart", { menu_item_id: @item.id }.to_json, id: "tc_str")
    assert_equal({ "menu_item_id" => @item.id }, @call_log.tool_invocations.sole.arguments)
  end

  test "unknown tool and empty-cart submit are recorded as rejected with their structured result" do
    assert_equal "unknown_tool", JSON.parse(tool("make_coffee", {}, id: "tc_unknown")).dig("error", "code")
    assert_equal "cart_empty", JSON.parse(tool("submit_order", { fulfillment_type: "pickup", cart_version: 0 }, id: "tc_empty")).dig("error", "code")

    unknown, empty = @call_log.tool_invocations.order(:id)
    assert_equal [ "rejected", "unknown_tool" ], [ unknown.status, unknown.error_code ]
    assert_equal [ "rejected", "cart_empty" ], [ empty.status, empty.error_code ]
  end

  test "an unexpected exception is recorded as error with its class; the model only gets internal_error" do
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { |*, **| raise "secret detail: connection to db-7 lost" }
    begin
      result = tool("add_to_cart", { menu_item_id: @item.id }, id: "tc_boom")
    ensure
      Order.define_method(:recompute_total!, original)
    end

    assert_equal "internal_error", JSON.parse(result).dig("error", "code")
    assert_no_match(/secret detail|db-7|RuntimeError/, result)
    invocation = @call_log.tool_invocations.sole
    assert_predicate invocation, :error?
    assert_equal "RuntimeError", invocation.error_class
    assert_equal "internal_error", invocation.error_code
    assert_equal result, invocation.result
  end

  test "malformed JSON arguments are a rejected invalid_arguments, recorded as received" do
    result = tool("add_to_cart", "{not json", id: "tc_bad")
    assert_equal "invalid_arguments", JSON.parse(result).dig("error", "code")
    invocation = @call_log.tool_invocations.sole
    assert_predicate invocation, :rejected?
    assert_equal "{not json", invocation.arguments
  end

  test "a redelivered toolCallId is still executed, and bumps replay_count on the original row" do
    2.times { tool("add_to_cart", { menu_item_id: @item.id }, id: "tc_dup") }

    assert_equal 2, @call_log.reload.order.order_items.count
    invocation = @call_log.tool_invocations.sole
    assert_equal 1, invocation.replay_count
  end

  test "no call log means nothing to attach to: same reply, no row" do
    assert_equal "no_active_call", JSON.parse(tool("get_cart", {}, id: "tc_none", call: "missing")).dig("error", "code")
    assert_equal 0, ToolInvocation.count
  end

  test "a tool call without an id is executed but not recorded" do
    vapi(type: "tool-calls", call: { id: "call_ti" }, toolCallList: [ { function: { name: "get_cart", arguments: {} } } ])
    assert_response :success
    assert_equal 0, ToolInvocation.count
  end

  test "a recording failure never changes the tool response" do
    expected = tool("get_cart", {}, id: "tc_before")

    original = ToolInvocation.method(:record!)
    ToolInvocation.define_singleton_method(:record!) { |**| raise ActiveRecord::StatementInvalid, "boom" }
    begin
      assert_equal expected, tool("get_cart", {}, id: "tc_during")
    ensure
      ToolInvocation.define_singleton_method(:record!, original)
    end
    assert_equal [ "tc_before" ], @call_log.tool_invocations.pluck(:tool_call_id)
  end

  test "oversized arguments are capped" do
    capped = ToolInvocation.cap_arguments({ "notes" => "x" * 10_000 })
    assert_equal true, capped["_truncated"]
    assert_operator capped.to_json.bytesize, :<, ToolInvocation::ARGUMENTS_BYTE_LIMIT

    small = { "a" => 1 }
    assert_equal small, ToolInvocation.cap_arguments(small)
  end
end

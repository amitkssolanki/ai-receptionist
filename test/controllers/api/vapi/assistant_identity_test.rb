require "test_helper"

# Phase 2: the server records which Vapi assistant handled a call (call_logs.assistant_id, from the authenticated
# webhook) so the console can label fault-injection calls. It is evidence only: the same webhook, tool path and rules
# apply to every assistant, and a premature submit is refused identically whichever assistant sends it.
class Api::Vapi::AssistantIdentityTest < ActionDispatch::IntegrationTest
  DEV_ID = "f858bbe9-0000-4000-8000-000000000001".freeze   # explicit test values, not real assistant ids
  FAULT_ID = "fa017000-0000-4000-8000-000000000002".freeze

  setup do
    ENV["VAPI_SERVER_SECRET"] = "test-vapi-secret"
    @restaurant = Restaurant.create!(name: "Identity Bistro", phone_number: "+15550007171", business_hours: ALWAYS_OPEN_HOURS)
    @item = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                       .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
  end

  teardown { ENV.delete("VAPI_SERVER_SECRET") }

  def vapi(message, secret: "test-vapi-secret")
    post api_vapi_webhooks_path, params: { message: message }, headers: { "X-Vapi-Secret" => secret }, as: :json
  end

  def start(call, assistant_id)
    vapi({ type: "status-update", status: "in-progress", call: { id: call, type: "webCall", assistantId: assistant_id }.compact })
    assert_response :success
    CallLog.find_by!(external_call_id: call)
  end

  def finish(call, assistant_id)
    vapi({ type: "end-of-call-report", call: { id: call, assistantId: assistant_id }.compact, endedReason: "customer-ended-call", artifact: {} })
    assert_response :success
  end

  def tool(call, assistant_id, id, name, arguments = {}, artifact: nil)
    message = { type: "tool-calls", call: { id: call, assistantId: assistant_id },
                toolCallList: [ { id: id, type: "function", function: { name: name, arguments: arguments } } ] }
    message[:artifact] = artifact if artifact
    vapi(message)
    assert_response :success
    JSON.parse(JSON.parse(response.body)["results"].first["result"])
  end

  # Live call #1's recorded premature submit (structure only), with its submit renamed to the id this test sends.
  def premature_history(submit_id)
    payload = JSON.parse(file_fixture("vapi/live_submit_webhook_call8.json").read)
    live_id = payload.dig("toolCallList", 0, "id")
    rename = ->(calls) { Array(calls).each { |t| t["id"] = submit_id if t["id"] == live_id } }
    payload["artifact"]["messages"].each { |m| rename.(m["toolCalls"]) }
    payload["artifact"]["messagesOpenAIFormatted"].each { |m| rename.(m["tool_calls"]) }
    payload["artifact"]
  end

  test "each call keeps the id of the assistant that handled it" do
    assert_equal DEV_ID, start("normal_call", DEV_ID).assistant_id
    assert_equal FAULT_ID, start("fault_call", FAULT_ID).assistant_id
    assert_nil start("unknown_call", nil).assistant_id
  end

  test "an unauthenticated webhook records nothing, whatever assistant it names" do
    vapi({ type: "status-update", status: "in-progress", call: { id: "forged", assistantId: FAULT_ID } }, secret: "wrong-secret-0000")
    assert_response :unauthorized
    assert_not CallLog.exists?(external_call_id: "forged")
  end

  test "the end-of-call report fills in a missing assistant id but never replaces a recorded one, and the id is sanitized" do
    start("late", nil)
    finish("late", FAULT_ID)
    assert_equal FAULT_ID, CallLog.find_by!(external_call_id: "late").assistant_id

    start("kept", DEV_ID)
    finish("kept", FAULT_ID)
    assert_equal DEV_ID, CallLog.find_by!(external_call_id: "kept").assistant_id

    assert_equal "abc-123<script>".gsub(/[^\w.\-]/, ""), start("junk", "abc-123<script>\n").assistant_id
    assert_equal 64, start("long", "a" * 200).assistant_id.size
  end

  test "call logging is otherwise unchanged: the end-of-call report still completes the record" do
    call_log = start("ended", DEV_ID)
    finish("ended", DEV_ID)
    call_log.reload
    assert_equal [ "abandoned", "customer-ended-call" ], [ call_log.status, call_log.ended_reason ]
    assert_predicate call_log.ended_at, :present?
  end

  test "a premature submit is refused identically whichever assistant sends it: no server path depends on the assistant" do
    outcomes = { DEV_ID => "normal", FAULT_ID => "fault" }.map do |assistant_id, call|
      call_log = start(call, assistant_id)
      tool(call, assistant_id, "add", "add_to_cart", { menu_item_id: @item.id })
      tool(call, assistant_id, "cart", "get_cart")
      result = tool(call, assistant_id, "submit", "submit_order", { fulfillment_type: "pickup", cart_version: 1 }, artifact: premature_history("submit"))
      row = call_log.tool_invocations.find_by!(tool_call_id: "submit")
      order = call_log.reload.order
      { result: result, row: row.attributes.slice("status", "error_code", "cart_version_before", "cart_version_after", "turn_evidence"),
        order: [ order.status, order.cart_version, order.read_back_version, order.placed_at ] }
    end

    normal, fault = outcomes
    assert_equal "customer_confirmation_required", fault[:result].dig("error", "code")
    assert_equal 0, fault[:row].dig("turn_evidence", "caller_turns_since_last_get_cart")
    assert_equal [ "pending", 1, 1, nil ], fault[:order], "nothing was submitted; the order is unchanged"
    assert_equal normal, fault, "the same refusal, record and order state for both assistants"
  end
end

require "test_helper"

# Shadow-mode confirmation instrumentation, through the real webhook path: submit_order records what Vapi's
# conversation history shows about caller turns, and NOTHING about the submit changes - same result, same order,
# same SMS decision - whatever the evidence says (no caller turn, same completion, missing or malformed history).
class Api::Vapi::SubmitTurnEvidenceTest < ActionDispatch::IntegrationTest
  SPOKEN = "SENTINEL words from the call".freeze

  setup do
    ENV["VAPI_SERVER_SECRET"] = "test-vapi-secret"
    @restaurant = Restaurant.create!(name: "Evidence Bistro", phone_number: "+15550009191", business_hours: ALWAYS_OPEN_HOURS)
    @item = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                       .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
  end

  teardown { ENV.delete("VAPI_SERVER_SECRET") }

  def vapi(message)
    post api_vapi_webhooks_path, params: { message: message }, headers: { "X-Vapi-Secret" => "test-vapi-secret" }, as: :json
  end

  def tool(call, id, name, arguments = {}, artifact: nil)
    message = { type: "tool-calls", call: { id: call }, toolCallList: [ { id: id, type: "function", function: { name: name, arguments: arguments } } ] }
    message[:artifact] = artifact unless artifact.nil?
    vapi(message)
    assert_response :success
    JSON.parse(response.body)["results"].first["result"]
  end

  # A cart read back at v1, ready for submit_order; returns the call log.
  def call_ready_to_submit(call)
    vapi(type: "status-update", status: "in-progress", call: { id: call, type: "webCall" })
    tool(call, "#{call}_add", "add_to_cart", { menu_item_id: @item.id })
    tool(call, "#{call}_cart", "get_cart")
    CallLog.find_by!(external_call_id: call)
  end

  # Vapi's shape (see test/fixtures/files/vapi/live_submit_webhook_call9.json), with spoken text as a sentinel.
  def history(call, caller_turns:, same_completion:)
    messages = [ { role: "tool_calls", time: 3_000, toolCalls: [ { id: "#{call}_cart", function: { name: "get_cart" } } ] },
                 { role: "tool_call_result", time: 3_500, name: "get_cart", toolCallId: "#{call}_cart", result: SPOKEN },
                 { role: "bot", time: 3_600, message: SPOKEN } ]
    caller_turns.times { |i| messages << { role: "user", time: 5_000 + i, message: SPOKEN } }
    messages << { role: "tool_calls", time: 9_000, toolCalls: [ { id: "#{call}_submit", function: { name: "submit_order" } } ] }
    messages << { role: "user", time: 9_100, message: SPOKEN }

    readback = { role: "assistant", content: SPOKEN }
    submit = { role: "assistant", content: nil, tool_calls: [ { id: "#{call}_submit", function: { name: "submit_order" } } ] }
    openai = [ { role: "assistant", content: nil, tool_calls: [ { id: "#{call}_cart", function: { name: "get_cart" } } ] },
               { role: "tool", tool_call_id: "#{call}_cart", content: SPOKEN } ]
    openai += same_completion ? [ readback.merge(submit.slice(:tool_calls)) ] : [ readback, { role: "user", content: SPOKEN }, submit ]
    { messages: messages, messagesOpenAIFormatted: openai, variableValues: {} }
  end

  def sms_jobs_during
    before = enqueued_jobs.count { |job| job["job_class"] == "OrderConfirmationSmsJob" }
    result = yield
    [ enqueued_jobs.count { |job| job["job_class"] == "OrderConfirmationSmsJob" } - before, result ]
  end

  def submit(call, artifact:) =tool(call, "#{call}_submit", "submit_order", { fulfillment_type: "pickup", cart_version: 1 }, artifact: artifact)
  def submit_row(call_log) = call_log.tool_invocations.find_by!(tool_name: "submit_order")
  def comparable(result) = JSON.parse(result).tap { |r| r["items"].each { |i| i.delete("id") } }

  test "no caller turn and read-back + submit in one completion: recorded, and the submit still goes through unchanged" do
    control = call_ready_to_submit("control")
    control_jobs, control_result = sms_jobs_during { submit("control", artifact: nil) }

    shadow = call_ready_to_submit("shadow")
    shadow_jobs, shadow_result = sms_jobs_during { submit("shadow", artifact: history("shadow", caller_turns: 0, same_completion: true)) }

    assert_equal comparable(control_result), comparable(shadow_result), "the model is told exactly the same thing"
    assert_equal control_jobs, shadow_jobs, "the same SMS decision"
    assert shadow.reload.order.confirmed?
    assert_equal [ control.reload.order.status, control.order.total_cents, control.order.placed_at.present? ],
                 [ shadow.order.status, shadow.order.total_cents, shadow.order.placed_at.present? ]

    evidence = submit_row(shadow).turn_evidence
    assert_equal [ "shadow", "present", 0, 1 ], evidence.values_at("mode", "artifact_messages", "caller_turns_since_last_get_cart", "caller_turns_after_submit_request")
    assert_equal true, evidence.dig("completion", "responds_to_get_cart_result")
    assert_equal "missing", submit_row(control).turn_evidence["artifact_messages"]
  end

  test "one caller turn and a later completion are recorded" do
    call_log = call_ready_to_submit("one_turn")
    submit("one_turn", artifact: history("one_turn", caller_turns: 1, same_completion: false))

    evidence = submit_row(call_log).turn_evidence
    assert_equal [ 1, false ], [ evidence["caller_turns_since_last_get_cart"], evidence.dig("completion", "responds_to_get_cart_result") ]
    assert call_log.reload.order.confirmed?
  end

  test "several caller turns are counted" do
    call_log = call_ready_to_submit("many")
    submit("many", artifact: history("many", caller_turns: 3, same_completion: false))
    assert_equal 3, submit_row(call_log).turn_evidence["caller_turns_since_last_get_cart"]
  end

  test "missing and malformed history never block or alter the submit" do
    { "no_history" => nil, "garbage" => "garbage", "bad_list" => { messages: { a: 1 } } }.each do |call, artifact|
      call_log = call_ready_to_submit(call)
      result = JSON.parse(submit(call, artifact: artifact))
      assert_equal [ true, "confirmed" ], [ result["ok"], call_log.reload.order.status ], call
      assert_equal (artifact.nil? ? "missing" : "malformed"), submit_row(call_log).turn_evidence["artifact_messages"], call
    end
  end

  test "an exception while observing is contained: the submit still goes through" do
    call_log = call_ready_to_submit("explodes")
    Voice::TurnEvidence.singleton_class.send(:alias_method, :__original_for_submit, :for_submit)
    Voice::TurnEvidence.define_singleton_method(:for_submit) { |*, **| raise ArgumentError, "boom" }
    begin
      result = JSON.parse(submit("explodes", artifact: history("explodes", caller_turns: 0, same_completion: true)))
    ensure
      Voice::TurnEvidence.singleton_class.send(:alias_method, :for_submit, :__original_for_submit)
      Voice::TurnEvidence.singleton_class.send(:remove_method, :__original_for_submit)
    end

    assert_equal [ true, "confirmed" ], [ result["ok"], call_log.reload.order.status ]
    assert_equal [ "malformed", "ArgumentError" ], submit_row(call_log).turn_evidence.values_at("artifact_messages", "error")
  end

  test "a refused submit is refused for its own reason, not the evidence; other tools carry no evidence" do
    vapi(type: "status-update", status: "in-progress", call: { id: "refused", type: "webCall" })
    tool("refused", "refused_add", "add_to_cart", { menu_item_id: @item.id }, artifact: { messages: [] })
    result = JSON.parse(submit("refused", artifact: history("refused", caller_turns: 2, same_completion: false)))

    call_log = CallLog.find_by!(external_call_id: "refused")
    assert_equal "readback_required", result.dig("error", "code"), "the existing read-back rule, unchanged"
    assert_equal 2, submit_row(call_log).turn_evidence["caller_turns_since_last_get_cart"]
    assert_nil call_log.tool_invocations.find_by!(tool_name: "add_to_cart").turn_evidence
  end

  test "no spoken text is persisted or returned" do
    call_log = call_ready_to_submit("private")
    result = submit("private", artifact: history("private", caller_turns: 1, same_completion: true))

    assert_not_includes result, "SENTINEL"
    call_log.tool_invocations.each { |row| assert_not_includes row.attributes.to_json, "SENTINEL" }
    assert_not_includes call_log.reload.attributes.to_json, "SENTINEL"
  end
end

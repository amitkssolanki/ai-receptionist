require "test_helper"

# The server-side confirmation gate, through the real webhook path: submit_order is refused
# (customer_confirmation_required) unless Vapi's conversation history shows at least one caller turn after the last
# get_cart result. It is a turn-taking gate: it never judges what the caller said. Missing or unreadable history fails
# closed. The live evidence for it: calls #1 and #6 (Vapi/DB calls #8, #13) submitted before the caller answered.
# Call #2 (#9) looked the same in its webhook history, but Vapi's model log shows the model had the caller's answer: the
# history stamps that turn 0.1 s after the submit, so the gate refuses it - a known false refusal (verification log,
# 2026-10-01). Structure-only copies of those webhooks are in test/fixtures/files/vapi/.
class Api::Vapi::ConfirmationGateTest < ActionDispatch::IntegrationTest
  SPOKEN = "SENTINEL words from the call".freeze

  setup do
    ENV["VAPI_SERVER_SECRET"] = "test-vapi-secret"
    @restaurant = Restaurant.create!(name: "Gate Bistro", phone_number: "+15550009191", business_hours: ALWAYS_OPEN_HOURS)
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

  # Vapi's shape (test/fixtures/files/vapi/live_submit_webhook_*.json) with a sentinel as the spoken text.
  def history(call, submit_id:, caller_turns:, same_completion: false, speech: SPOKEN)
    messages = [ { role: "tool_calls", time: 3_000, toolCalls: [ { id: "#{call}_cart", function: { name: "get_cart" } } ] },
                 { role: "tool_call_result", time: 3_500, name: "get_cart", toolCallId: "#{call}_cart", result: SPOKEN },
                 { role: "bot", time: 3_600, message: speech } ]
    caller_turns.times { |i| messages << { role: "user", time: 5_000 + i, message: SPOKEN } }
    messages << { role: "tool_calls", time: 9_000, toolCalls: [ { id: submit_id, function: { name: "submit_order" } } ] }

    submit = { role: "assistant", content: nil, tool_calls: [ { id: submit_id, function: { name: "submit_order" } } ] }
    openai = [ { role: "assistant", content: nil, tool_calls: [ { id: "#{call}_cart", function: { name: "get_cart" } } ] },
               { role: "tool", tool_call_id: "#{call}_cart", content: SPOKEN } ]
    openai += if same_completion
      [ submit.merge(content: speech) ]
    else
      [ { role: "assistant", content: speech } ] + Array.new(caller_turns) { { role: "user", content: SPOKEN } } + [ submit ]
    end
    { messages: messages, messagesOpenAIFormatted: openai, variableValues: {} }
  end

  def submit(call, id, artifact:) = JSON.parse(tool(call, id, "submit_order", { fulfillment_type: "pickup", cart_version: 1 }, artifact: artifact))
  def row(call_log, id) = call_log.tool_invocations.find_by!(tool_call_id: id)
  def sms_jobs = enqueued_jobs.count { |job| job["job_class"] == "OrderConfirmationSmsJob" }

  def assert_refused(result, call_log, id)
    assert_equal false, result["ok"]
    assert_equal "customer_confirmation_required", result.dig("error", "code")
    assert_equal 1, result.dig("error", "cart_version"), "tells the model which version to submit once the caller answers"
    order = call_log.reload.order
    assert_equal [ "pending", nil ], [ order.status, order.placed_at ], "nothing was submitted"
    assert_equal [ "rejected", "customer_confirmation_required" ], [ row(call_log, id).status, row(call_log, id).error_code ]
  end

  # 1
  test "submit_order right after get_cart with zero caller turns is refused, and the refusal is recorded" do
    call_log = call_ready_to_submit("zero")
    jobs_before = sms_jobs
    result = submit("zero", "zero_s", artifact: history("zero", submit_id: "zero_s", caller_turns: 0))

    assert_refused(result, call_log, "zero_s")
    assert_equal jobs_before, sms_jobs, "no SMS for a refused submit"
    evidence = row(call_log, "zero_s").turn_evidence
    assert_equal [ "enforced", "present", 0 ], evidence.values_at("mode", "artifact_messages", "caller_turns_since_last_get_cart")
  end

  # 2
  test "submit_order after one caller turn is accepted" do
    call_log = call_ready_to_submit("one")
    result = submit("one", "one_s", artifact: history("one", submit_id: "one_s", caller_turns: 1))

    assert_equal [ true, 1 ], result.values_at("ok", "cart_version")
    assert call_log.reload.order.confirmed?
    assert_equal 1, row(call_log, "one_s").turn_evidence["caller_turns_since_last_get_cart"]
  end

  # 3
  test "a caller turn after get_cart with the submit in a later model completion is accepted" do
    call_log = call_ready_to_submit("later")
    result = submit("later", "later_s", artifact: history("later", submit_id: "later_s", caller_turns: 2, same_completion: false))

    assert result["ok"]
    evidence = row(call_log, "later_s").turn_evidence
    assert_equal [ 2, false ], [ evidence["caller_turns_since_last_get_cart"], evidence.dig("completion", "responds_to_get_cart_result") ]
  end

  # 4
  test "read-back and submit in the same model completion, with no caller turn, is refused" do
    call_log = call_ready_to_submit("same")
    result = submit("same", "same_s", artifact: history("same", submit_id: "same_s", caller_turns: 0, same_completion: true))

    assert_refused(result, call_log, "same_s")
    assert_equal true, row(call_log, "same_s").turn_evidence.dig("completion", "responds_to_get_cart_result")
  end

  # 5
  test "missing or malformed history fails closed for submission, without crashing" do
    { "none" => nil, "garbage" => "garbage", "bad_list" => { messages: { a: 1 } }, "no_submit_entry" => { messages: [ { role: "user", time: 1 } ] },
      "no_get_cart" => { messages: [ { role: "user", time: 1 }, { role: "tool_calls", time: 2, toolCalls: [ { id: "no_get_cart_s", function: { name: "submit_order" } } ] } ] } }
      .each do |call, artifact|
        call_log = call_ready_to_submit(call)
        result = submit(call, "#{call}_s", artifact: artifact)
        assert_refused(result, call_log, "#{call}_s")
      end
  end

  test "an exception while reading the history fails closed" do
    call_log = call_ready_to_submit("explodes")
    Voice::TurnEvidence.singleton_class.send(:alias_method, :__original_for_submit, :for_submit)
    Voice::TurnEvidence.define_singleton_method(:for_submit) { |*, **| raise ArgumentError, "boom" }
    begin
      result = submit("explodes", "explodes_s", artifact: history("explodes", submit_id: "explodes_s", caller_turns: 1))
    ensure
      Voice::TurnEvidence.singleton_class.send(:alias_method, :for_submit, :__original_for_submit)
      Voice::TurnEvidence.singleton_class.send(:remove_method, :__original_for_submit)
    end

    assert_refused(result, call_log, "explodes_s")
    assert_equal [ "malformed", "ArgumentError" ], row(call_log, "explodes_s").turn_evidence.values_at("artifact_messages", "error")
  end

  # 6
  test "a duplicate delivery of a refused submit returns the stored refusal and changes nothing" do
    call_log = call_ready_to_submit("dup_refused")
    first = submit("dup_refused", "dup_s", artifact: history("dup_refused", submit_id: "dup_s", caller_turns: 0))
    # The redelivery carries a history that WOULD pass; the stored result is returned, nothing is re-executed.
    again = submit("dup_refused", "dup_s", artifact: history("dup_refused", submit_id: "dup_s", caller_turns: 1))

    assert_equal first, again
    assert_refused(again, call_log, "dup_s")
    assert_equal 1, row(call_log, "dup_s").replay_count
  end

  # 7
  test "an already-submitted order stays idempotent, even for a later submit with no caller turn" do
    call_log = call_ready_to_submit("done")
    submit("done", "done_s1", artifact: history("done", submit_id: "done_s1", caller_turns: 1))
    placed_at = call_log.reload.order.placed_at
    jobs = sms_jobs
    later = submit("done", "done_s2", artifact: history("done", submit_id: "done_s2", caller_turns: 0))

    assert_equal [ true, true ], later.values_at("ok", "already_submitted")
    assert_equal [ "confirmed", placed_at ], [ call_log.reload.order.status, call_log.order.placed_at ]
    assert_equal jobs, sms_jobs
  end

  # 8
  test "the gate persists no transcript text" do
    call_log = call_ready_to_submit("private")
    refused = submit("private", "private_a", artifact: history("private", submit_id: "private_a", caller_turns: 0))
    accepted = submit("private", "private_b", artifact: history("private", submit_id: "private_b", caller_turns: 1))

    assert_not_includes refused.to_json + accepted.to_json, "SENTINEL"
    call_log.tool_invocations.each { |r| assert_not_includes r.attributes.to_json, "SENTINEL" }
    assert_not_includes call_log.reload.attributes.to_json, "SENTINEL"
  end

  # 9
  test "speech_chars has no influence on the decision" do
    { "silent" => "", "long" => "x" * 500 }.each do |label, speech|
      call_log = call_ready_to_submit("speech_#{label}")
      refused = submit("speech_#{label}", "#{label}_a", artifact: history("speech_#{label}", submit_id: "#{label}_a", caller_turns: 0, same_completion: true, speech: speech))
      assert_refused(refused, call_log, "#{label}_a")
      accepted = submit("speech_#{label}", "#{label}_b", artifact: history("speech_#{label}", submit_id: "#{label}_b", caller_turns: 1, speech: speech))
      assert accepted["ok"], label
    end
  end

  # 10
  test "tools other than submit_order behave exactly as before and record no turn evidence" do
    with_history = call_ready_to_submit("other_a")
    without = call_ready_to_submit("other_b")
    comparable = ->(result) { JSON.parse(result).tap { |r| r["items"]&.each { |i| i.delete("id") } } }
    artifact = history("other_a", submit_id: "unused", caller_turns: 0)

    assert_equal comparable.(tool("other_b", "b_add", "add_to_cart", { menu_item_id: @item.id })),
                 comparable.(tool("other_a", "a_add", "add_to_cart", { menu_item_id: @item.id }, artifact: artifact))
    assert_equal comparable.(tool("other_b", "b_cart", "get_cart")), comparable.(tool("other_a", "a_cart", "get_cart", {}, artifact: artifact))
    [ with_history, without ].each { |call_log| assert call_log.tool_invocations.where.not(tool_name: "submit_order").all? { |r| r.turn_evidence.nil? } }
  end

  test "the other submit rules still come first: no read-back is readback_required, whatever the history says" do
    vapi(type: "status-update", status: "in-progress", call: { id: "no_read", type: "webCall" })
    tool("no_read", "no_read_add", "add_to_cart", { menu_item_id: @item.id })
    result = submit("no_read", "no_read_s", artifact: history("no_read", submit_id: "no_read_s", caller_turns: 1))
    assert_equal "readback_required", result.dig("error", "code")
  end

  # --- the real live structures ---

  def live(name) = JSON.parse(file_fixture("vapi/live_submit_webhook_#{name}.json").read)

  # The live history, with its submit's tool-call id renamed to the one this test sends.
  def live_history(name, submit_id)
    payload = live(name)
    live_id = payload.dig("toolCallList", 0, "id")
    rename = ->(calls) { Array(calls).each { |t| t["id"] = submit_id if t["id"] == live_id } }
    payload["artifact"]["messages"].each { |m| rename.(m["toolCalls"]) }
    payload["artifact"]["messagesOpenAIFormatted"].each { |m| rename.(m["tool_calls"]) }
    payload["artifact"]
  end

  test "the recorded submits of live calls #1, #2 and #6 are each refused (#1 and #6 premature; #2 a false refusal)" do
    %w[call8 call9 call13_first].each do |name|
      call_log = call_ready_to_submit("live_#{name}")
      assert_refused(submit("live_#{name}", "#{name}_s", artifact: live_history(name, "#{name}_s")), call_log, "#{name}_s")
    end
  end

  test "live call #6 end to end: the premature submit is refused, the submit after the caller's yes is accepted, a repeat is absorbed" do
    call_log = call_ready_to_submit("call6")
    premature = submit("call6", "c6_first", artifact: live_history("call13_first", "c6_first"))
    assert_refused(premature, call_log, "c6_first")

    answered = submit("call6", "c6_second", artifact: live_history("call13_second", "c6_second"))
    assert answered["ok"]
    assert call_log.reload.order.confirmed?
    assert_equal 1, row(call_log, "c6_second").turn_evidence["caller_turns_since_last_get_cart"]

    repeat = submit("call6", "c6_second", artifact: live_history("call13_second", "c6_second"))
    assert_equal answered, repeat, "the same delivery again: stored result"
    later = submit("call6", "c6_third", artifact: live_history("call13_first", "c6_third"))
    assert_equal true, later["already_submitted"], "already submitted: idempotent, not re-gated"
  end
end

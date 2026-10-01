require "test_helper"

# Turn evidence (Voice::TurnEvidence): what Vapi's conversation history shows about caller turn-taking when
# submit_order is requested, and the confirmation gate's predicate built on it (at least one caller turn after the last
# get_cart result; everything else fails closed). The gate's behaviour through the webhook is in
# test/controllers/api/vapi/confirmation_gate_test.rb.
class Voice::TurnEvidenceTest < ActiveSupport::TestCase
  SPOKEN = "SENTINEL spoken words that must never be stored".freeze

  # --- builders in the live payload's shape (see test/fixtures/files/vapi/live_submit_webhook_call9.json) ---

  def speech(role, time) = { "role" => role, "message" => SPOKEN, "time" => time, "endTime" => time + 500, "secondsFromStart" => time / 1000.0 }
  def bot(time) = speech("bot", time)
  def caller(time) = speech("user", time)
  def requested(time, *calls) = { "role" => "tool_calls", "time" => time, "toolCalls" => calls.map { |id, name| { "id" => id, "type" => "function", "function" => { "name" => name } } } }
  def answered(time, id, name) = { "role" => "tool_call_result", "time" => time, "name" => name, "toolCallId" => id, "result" => SPOKEN }

  def assistant(content, *calls)
    { "role" => "assistant", "content" => content }.merge(calls.any? ? { "tool_calls" => calls.map { |id, name| { "id" => id, "type" => "function", "function" => { "name" => name } } } } : {})
  end
  def tool_message(id) = { "role" => "tool", "tool_call_id" => id, "content" => SPOKEN }
  def user_message = { "role" => "user", "content" => SPOKEN }

  def evidence(messages, openai = nil, id: "s1") = Voice::TurnEvidence.for_submit({ "messages" => messages, "messagesOpenAIFormatted" => openai }, tool_call_id: id)

  # Call #9's pattern: the read-back and the submit in one completion, the caller's reply only after the submit.
  def chained_history
    messages = [ bot(1_000), caller(2_000), requested(3_000, %w[c1 get_cart]), answered(3_500, "c1", "get_cart"), bot(3_600),
                 requested(15_000, %w[s1 submit_order]), caller(15_100) ]
    openai = [ assistant("hi"), user_message, assistant(nil, %w[c1 get_cart]), tool_message("c1"),
               assistant("One pizza, sixteen dollars. Did I get that right?", %w[s1 submit_order]), tool_message("s1"), user_message ]
    [ messages, openai ]
  end

  test "1. history present, no caller turn after the last get_cart; a reply that began after the submit is not counted" do
    e = evidence(*chained_history)

    assert_equal "present", e["artifact_messages"]
    assert_equal [ 0, 1, true ], e.values_at("caller_turns_since_last_get_cart", "caller_turns_after_submit_request", "submit_request_found")
    assert_equal [ 11_500, 100 ], e.values_at("ms_last_get_cart_result_to_submit_request", "ms_submit_request_to_next_caller_turn")
    assert_equal "c1", e["last_get_cart_tool_call_id"]
    assert_equal [], e["anomalies"]
    assert_equal "enforced", e["mode"]
  end

  test "2. one caller turn after the last get_cart, submit from a later completion" do
    messages = [ requested(3_000, %w[c1 get_cart]), answered(3_500, "c1", "get_cart"), bot(3_600), caller(9_000),
                 requested(10_000, %w[s1 submit_order]) ]
    openai = [ assistant(nil, %w[c1 get_cart]), tool_message("c1"), assistant("One pizza. Did I get that right?"), user_message,
               assistant("Placing it now.", %w[s1 submit_order]) ]
    e = evidence(messages, openai)

    assert_equal 1, e["caller_turns_since_last_get_cart"]
    assert_equal 0, e["caller_turns_after_submit_request"]
    assert_nil e["ms_submit_request_to_next_caller_turn"]
    assert_equal false, e.dig("completion", "responds_to_get_cart_result")
  end

  test "3. several caller turns are counted; speech during the get_cart request and agent speech are not" do
    messages = [ requested(3_000, %w[c0 get_cart]), caller(3_100), answered(3_500, "c0", "get_cart"), bot(3_600), caller(8_000),
                 bot(8_500), caller(9_000), caller(9_600), requested(10_000, %w[s1 submit_order]) ]
    assert_equal 3, evidence(messages)["caller_turns_since_last_get_cart"]
  end

  test "counting restarts at the most recent get_cart result" do
    messages = [ answered(1_000, "c0", "get_cart"), caller(2_000), caller(3_000), requested(4_000, %w[c1 get_cart]),
                 answered(4_500, "c1", "get_cart"), requested(5_000, %w[s1 submit_order]) ]
    e = evidence(messages)
    assert_equal [ 0, "c1" ], e.values_at("caller_turns_since_last_get_cart", "last_get_cart_tool_call_id")
  end

  test "4. missing history is reported as missing" do
    assert_equal "missing", Voice::TurnEvidence.for_submit(nil, tool_call_id: "s1")["artifact_messages"]
    assert_equal "missing", Voice::TurnEvidence.for_submit({ "variables" => {} }, tool_call_id: "s1")["artifact_messages"]
    assert_equal [ "schema", "mode", "artifact_messages" ], Voice::TurnEvidence.for_submit(nil, tool_call_id: "s1").keys
  end

  test "5. read-back and submit in the same assistant completion" do
    completion = evidence(*chained_history)["completion"]
    assert_equal({ "available" => true, "found" => true, "responds_to_get_cart_result" => true,
                   "speech_chars" => "One pizza, sixteen dollars. Did I get that right?".length, "tool_calls" => [ "submit_order" ] }, completion)
  end

  test "5b. get_cart and submit_order requested together in one completion" do
    messages = [ caller(1_000), requested(2_000, %w[c1 get_cart], %w[s1 submit_order]), answered(2_400, "c1", "get_cart") ]
    openai = [ user_message, assistant("One moment.", %w[c1 get_cart], %w[s1 submit_order]), tool_message("c1") ]
    e = evidence(messages, openai)

    assert_nil e["caller_turns_since_last_get_cart"], "no get_cart result preceded the submit request"
    assert_nil e["last_get_cart_tool_call_id"]
    assert_equal [ %w[get_cart submit_order], false ], e["completion"].values_at("tool_calls", "responds_to_get_cart_result")
  end

  test "6. submit in a later assistant completion than the read-back" do
    messages, = chained_history
    openai = [ assistant(nil, %w[c1 get_cart]), tool_message("c1"), assistant("Did I get that right?"), user_message,
               assistant(nil, %w[s1 submit_order]) ]
    completion = evidence(messages, openai)["completion"]
    assert_equal [ true, false, 0 ], completion.values_at("found", "responds_to_get_cart_result", "speech_chars")
  end

  test "7. malformed or unexpected structures fail safely" do
    assert_equal "malformed", Voice::TurnEvidence.for_submit("garbage", tool_call_id: "s1")["artifact_messages"]
    assert_equal "malformed", Voice::TurnEvidence.for_submit({ "messages" => { "a" => 1 } }, tool_call_id: "s1")["artifact_messages"]

    odd = evidence([ nil, "x", 3, { "role" => "tool_calls", "toolCalls" => "nope" }, answered("soon", "c1", "get_cart"),
                     { "role" => "tool_calls", "time" => "abc", "toolCalls" => [ nil, { "id" => "s1" } ] } ], "not a list")
    assert_equal "present", odd["artifact_messages"]
    assert_equal [ true, 0, nil ], odd.values_at("submit_request_found", "caller_turns_since_last_get_cart", "ms_last_get_cart_result_to_submit_request")
    assert_includes odd["anomalies"], "non_object_entries"
    assert_equal({ "available" => false }, odd["completion"])

    exploding = Class.new(Hash) { def [](*) = raise(ArgumentError, "boom") }.new
    broken = evidence([ exploding ])
    assert_equal [ "malformed", "ArgumentError" ], broken.values_at("artifact_messages", "error")
  end

  test "a submit id missing from the history is flagged, and the whole list is used" do
    messages = [ answered(1_000, "c1", "get_cart"), caller(2_000) ]
    e = evidence(messages, [], id: "s_other")
    assert_equal [ false, 1, nil ], e.values_at("submit_request_found", "caller_turns_since_last_get_cart", "caller_turns_after_submit_request")
    assert_includes e["anomalies"], "submit_request_not_in_history"
    assert_equal({ "available" => true, "found" => false }, e["completion"])
  end

  test "never returns spoken text: counts, flags, ids and lengths only" do
    json = evidence(*chained_history).to_json
    assert_not_includes json, "SENTINEL"
    assert_not_includes json, "sixteen"
  end

  # --- regression against the real structure of the live submit webhooks ---

  def live(call) = JSON.parse(file_fixture("vapi/live_submit_webhook_#{call}.json").read)

  test "live call #9's webhook history: read-back and submit in one message, 0 caller turns, the 'yes' stamped 104 ms after the submit" do
    payload = live("call9")
    e = Voice::TurnEvidence.for_submit(payload["artifact"], tool_call_id: payload.dig("toolCallList", 0, "id"))

    assert_equal [ "present", 35, true ], e.values_at("artifact_messages", "messages_count", "submit_request_found")
    assert_equal [ 0, 1 ], e.values_at("caller_turns_since_last_get_cart", "caller_turns_after_submit_request")
    assert_equal [ 11_743, 104 ], e.values_at("ms_last_get_cart_result_to_submit_request", "ms_submit_request_to_next_caller_turn")
    assert_equal "call_32WcoL8hYxof5rD4bU2S6CPa", e["last_get_cart_tool_call_id"]
    assert_equal [ true, 118, [ "submit_order" ] ], e["completion"].values_at("responds_to_get_cart_result", "speech_chars", "tool_calls")
    assert_equal [], e["anomalies"]
  end

  test "live call #8: 0 caller turns; the completion answering get_cart spoke only 44 characters and submitted" do
    payload = live("call8")
    e = Voice::TurnEvidence.for_submit(payload["artifact"], tool_call_id: payload.dig("toolCallList", 0, "id"))

    assert_equal [ 51, 0, 0 ], e.values_at("messages_count", "caller_turns_since_last_get_cart", "caller_turns_after_submit_request")
    assert_equal 783, e["ms_last_get_cart_result_to_submit_request"]
    assert_equal "call_ES9d2qnU0EElkbW67zOoHhiM", e["last_get_cart_tool_call_id"]
    assert_equal [ true, 44 ], e["completion"].values_at("responds_to_get_cart_result", "speech_chars")
  end

  # --- the gate's predicate ---

  def gate?(evidence) = Voice::TurnEvidence.caller_turn_after_read_back?(evidence)

  test "the predicate needs a readable history, the submit found in it, and at least one caller turn" do
    messages, openai = chained_history
    assert_not gate?(evidence(messages, openai)), "0 caller turns"
    answered = [ bot(1_000), requested(3_000, %w[c1 get_cart]), answered(3_500, "c1", "get_cart"), caller(4_000), requested(5_000, %w[s1 submit_order]) ]
    assert gate?(evidence(answered))
    assert_not gate?(evidence(answered, id: "s_other")), "submit not in the history"
    assert_not gate?(evidence([ caller(1_000), requested(2_000, %w[s1 submit_order]) ])), "no get_cart result in the history"
    [ nil, "garbage", { "messages" => { "a" => 1 } }, {} ].each { |artifact| assert_not gate?(Voice::TurnEvidence.for_submit(artifact, tool_call_id: "s1")), artifact.inspect }
    assert_not gate?(nil)
    assert_not gate?({ "artifact_messages" => "present", "submit_request_found" => true, "caller_turns_since_last_get_cart" => "1" }), "only an Integer count"
  end

  test "the predicate ignores the completion and speech_chars" do
    base = { "artifact_messages" => "present", "submit_request_found" => true }
    assert gate?(base.merge("caller_turns_since_last_get_cart" => 1, "completion" => { "responds_to_get_cart_result" => true, "speech_chars" => 0 }))
    assert_not gate?(base.merge("caller_turns_since_last_get_cart" => 0, "completion" => { "responds_to_get_cart_result" => false, "speech_chars" => 900 }))
  end

  test "on the real live submits: calls #1, #2 (a false refusal) and #6's first submit fail the gate; #6's second submit passes" do
    { "call8" => false, "call9" => false, "call13_first" => false, "call13_second" => true }.each do |name, expected|
      payload = live(name)
      e = Voice::TurnEvidence.for_submit(payload["artifact"], tool_call_id: payload.dig("toolCallList", 0, "id"))
      assert_equal expected, gate?(e), name
    end
  end

  test "live call #6: the first submit answered the get_cart result directly; the second came after one caller turn" do
    first, second = %w[call13_first call13_second].map do |name|
      payload = live(name)
      Voice::TurnEvidence.for_submit(payload["artifact"], tool_call_id: payload.dig("toolCallList", 0, "id"))
    end
    assert_equal [ 0, true, 1_164 ], [ first["caller_turns_since_last_get_cart"], first.dig("completion", "responds_to_get_cart_result"), first["ms_last_get_cart_result_to_submit_request"] ]
    assert_equal [ 1, false ], [ second["caller_turns_since_last_get_cart"], second.dig("completion", "responds_to_get_cart_result") ]
  end
end

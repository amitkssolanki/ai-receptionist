require "test_helper"

class ConsoleViewTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(name: "View Bistro", phone_number: "+15550006464", business_hours: ALWAYS_OPEN_HOURS, timezone: "America/New_York")
    category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @cheese = @burger.menu_item_modifiers.create!(name: "Extra cheese", price_cents: 150)
    @call = CallLifecycle.start(external_call_id: "view_1", dialed_number: @restaurant.phone_number, caller_number: "unknown-view_1".then { nil })
  end

  # submit_order carries a history in which the caller answered the read-back (the confirmation gate's input, see
  # VapiHistory); the gate itself is tested in test/controllers/api/vapi/confirmation_gate_test.rb.
  def run_tool(id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(@call.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } },
                           artifact: VapiHistory.for_tool(name, id))
  end

  def board = ConsoleView::Board.new(CallLog.find(@call.id))
  def events = ConsoleView::Timeline.new(CallLog.find(@call.id)).tool_events

  test "dom tokens keep provider ids DOM-safe and match the JavaScript rule" do
    { "call_DeA64Ufy8pFTMgfLwZh4hQio" => "call_DeA64Ufy8pFTMgfLwZh4hQio", "a b/c.d" => "a_b_c_d", "x\"><script>" => "x___script_", nil => "" }.each do |input, expected|
      assert_equal expected, ConsoleView.dom_token(input)
    end
    assert_equal 80, ConsoleView.dom_token("x" * 200).length
  end

  test "board before any cart" do
    b = board
    assert_not b.present?
    assert_equal [ "NO CART YET", 0, [], "n/a", "no cart yet" ], [ b.status_label, b.cart_version, b.lines, b.sms, b.confirmation ]
  end

  test "board follows the order through read-back, staleness, confirmation and abandonment" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id, "modifier_ids" => [ @cheese.id ] })
    assert_equal [ "CART OPEN", "not delivered", "awaiting read-back", 1 ], [ board.status_label, board.read_back, board.confirmation, board.cart_version ]
    assert_equal [ [ 1, "Burger", [ { name: "Extra cheese", price: 1.5 } ], 11.5 ] ], board.lines.map { |l| [ l.quantity, l.name, l.modifiers, l.subtotal ] }

    run_tool("c", "get_cart")
    assert_match(/\Adelivered for v1 at \d\d:\d\d:\d\d\z/, board.read_back)
    assert_equal "ready to submit (needs v1)", board.confirmation

    run_tool("b", "add_to_cart", { "menu_item_id" => @burger.id })
    assert_equal "STALE: cart v2, read-back v1", board.read_back
    assert_predicate board, :read_back_stale?
    assert_equal "awaiting read-back", board.confirmation

    run_tool("c2", "get_cart")
    run_tool("s", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 })
    assert_equal [ "CONFIRMED", true, "not sent: web call, no phone number" ], [ board.status_label, board.locked?, board.sms ]
    assert_match(/\Asubmitted v2 at \d\d:\d\d:\d\d\z/, board.confirmation)

    run_tool("s2", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 }) # new id, same order
    run_tool("s", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 })   # same id
    assert_match(/duplicate submit absorbed ×2\z/, board.confirmation)
  end

  test "board of an abandoned cart and of a delivery order never shows the address" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    CallLifecycle.finish(external_call_id: "view_1", transcript: nil, recording_url: nil)
    assert_equal [ "ABANDONED", "abandoned: never submitted" ], [ board.status_label, board.confirmation ]

    other = CallLifecycle.start(external_call_id: "view_2", dialed_number: @restaurant.phone_number, caller_number: "+15557773333")
    [ [ "a", "add_to_cart", { "menu_item_id" => @burger.id } ], [ "c", "get_cart", {} ],
      [ "s", "submit_order", { "fulfillment_type" => "delivery", "cart_version" => 1, "delivery_address" => "9 SECRET ROAD" } ] ].each do |id, name, args|
      Voice::ToolRunner.call(call_log: other, tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } }, artifact: VapiHistory.for_tool(name, id))
    end
    view = ConsoleView::Board.new(other.reload)
    assert_equal [ "delivery (address on file)", "confirmation text queued" ], [ view.fulfillment, view.sms ]
    assert_no_match(/SECRET ROAD/, [ view.fulfillment, view.confirmation, view.read_back ].join)
  end

  test "event rows resolve ids to names and summarise free text instead of echoing it" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id, "modifier_ids" => [ @cheese.id ], "quantity" => 2, "notes" => "no onions please" })
    line = @call.reload.order.order_items.sole
    run_tool("u", "update_cart_item_quantity", { "order_item_id" => line.id, "quantity" => 3 })
    run_tool("r", "remove_cart_item", { "order_item_id" => line.id })
    run_tool("m", "get_menu_item", { "menu_item_id" => @burger.id })
    run_tool("t", "transfer_to_human", { "reason" => "asked for the owner" })
    summaries = events.to_h { |e| [ e.invocation.tool_call_id, e.arguments_summary ] }

    assert_equal "2× Burger · Extra cheese · notes: 16 chars", summaries["a"]
    assert_equal "line #{line.id} (Burger) → qty 3", summaries["u"]
    assert_equal "Burger", summaries["m"]
    assert_equal "reason: asked for the owner", summaries["t"]
    assert_no_match(/no onions/, summaries.values.join)
  end

  test "event rows: results, cart versions, status badges and malformed arguments" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("bad", "add_to_cart", { "menu_item_id" => @burger.id, "quantity" => 99 })
    run_tool("junk", "add_to_cart", "{not json")
    run_tool("g", "get_cart")
    by_id = events.index_by { |e| e.invocation.tool_call_id }

    assert_equal [ "v0 → v1", "✓ ok", true ], [ by_id["a"].cart_label, by_id["a"].badge, by_id["a"].cart_changed? ]
    assert_match(/Added one Burger/, by_id["a"].result_summary)
    assert_equal [ "v1", "⛔ rejected · quantity_out_of_range", false ], [ by_id["bad"].cart_label, by_id["bad"].badge, by_id["bad"].cart_changed? ]
    assert_match(/\Aquantity_out_of_range: Quantity must be/, by_id["bad"].result_summary)
    assert_equal "(unparseable arguments)", by_id["junk"].arguments_summary
    assert_equal "read-back v1 · total $10.00", by_id["g"].result_summary
    assert_match(/\A\d\d:\d\d\z/, by_id["g"].offset)
  end

  test "the timeline orders tool rows and lifecycle entries by server time" do
    travel_to Time.zone.local(2026, 9, 30, 12, 0, 0) do
      @call.update!(started_at: Time.current)
      travel 10.seconds
      run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
      travel 20.seconds
      CallLifecycle.transfer(CallLog.find(@call.id), "a person")
      travel 5.seconds
      CallLifecycle.finish(external_call_id: "view_1", transcript: nil, recording_url: nil, outcome: { ended_reason: "assistant-ended-call", duration_seconds: 35, cost: 0.05 })
    end
    entries = ConsoleView::Timeline.new(CallLog.find(@call.id)).entries
    assert_equal [ "call started", "add_to_cart", "transferred to a person: a person", "call ended · assistant-ended-call · 35s · $0.0500" ],
                 entries.map { |e| e.is_a?(ConsoleView::Timeline::LifecycleEntry) ? e.text : e.tool }
    assert_equal %w[00:00 00:10 00:30 00:35], entries.map { |e| e.is_a?(ConsoleView::Timeline::LifecycleEntry) ? e.offset : e.offset }
  end

  test "status tallies tools and absorbed duplicates" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("x", "nope")
    status = ConsoleView::Status.new(CallLog.find(@call.id))
    assert_equal [ { ok: 1, rejected: 1, error: 0 }, 1, "IN PROGRESS" ], [ status.tools, status.duplicates_absorbed, status.label ]
  end

  # --- observations from the first live call (display only) ---

  test "the board points out a menu item that sits on two lines, without merging or refusing anything" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    assert_empty board.repeated_items
    run_tool("b", "add_to_cart", { "menu_item_id" => @burger.id, "modifier_ids" => [ @cheese.id ] })

    assert_equal [ { name: "Burger", lines: 2 } ], board.repeated_items
    assert_equal 2, CallLog.find(@call.id).order.order_items.count, "nothing was merged"
  end

  test "an add that leaves the same item on two lines is noted on its event row" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("b", "add_to_cart", { "menu_item_id" => @burger.id, "modifier_ids" => [ @cheese.id ] })
    by_id = events.index_by { |e| e.invocation.tool_call_id }

    assert_empty by_id["a"].observations
    assert_equal [ "Burger is now on 2 lines of the cart" ], by_id["b"].observations.map(&:text)
  end

  def timing(event) = event.observations.select { |o| o.icon == "⏱" }
  def shadow(event) = event.observations.select { |o| o.icon == "◌" }

  # Call #9: read-back and submit came from one model completion; the 12.9 s were the agent's own speech. Elapsed time
  # is therefore shown as latency only - never amber, never presented as time the caller had to answer.
  test "a submit row shows elapsed time since the last get_cart as latency only, never as a warning" do
    travel_to Time.zone.local(2026, 9, 30, 12, 0, 0) do
      run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
      run_tool("c1", "get_cart")
      travel 2.seconds
      run_tool("s1", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })

      quick = timing(events.find { |e| e.invocation.tool_call_id == "s1" }).sole
      assert_equal "2.0 s since the last get_cart (elapsed time only, includes the agent's speech; not evidence the caller answered)", quick.text
      assert_not quick.warn
    end
  end

  test "a refused submit is never blocked or altered by the observation, and other tools carry none" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("s", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) # no read-back: refused by the server rule
    refused = events.find { |e| e.invocation.tool_call_id == "s" }
    assert_equal "readback_required", refused.code
    assert_equal [ "no get_cart before this submit" ], timing(refused).map(&:text)
    assert_empty events.find { |e| e.invocation.tool_call_id == "a" }.observations
  end

  # --- shadow-mode turn evidence (observation only, recorded from Vapi's conversation history) ---

  def submit_with(artifact)
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("c", "get_cart")
    Voice::ToolRunner.call(call_log: CallLog.find(@call.id), artifact: artifact,
                           tool_call: { "id" => "s", "function" => { "name" => "submit_order", "arguments" => { "fulfillment_type" => "pickup", "cart_version" => 1 } } })
    events.find { |e| e.invocation.tool_call_id == "s" }
  end

  test "a chained read-back + submit (the call #9 pattern) is refused by the gate, with the turn evidence shown" do
    payload = JSON.parse(file_fixture("vapi/live_submit_webhook_call9.json").read)
    payload["artifact"]["messages"].each { |m| m["toolCalls"]&.each { |t| t["id"] = "s" if t["id"] == payload.dig("toolCallList", 0, "id") } }
    payload["artifact"]["messagesOpenAIFormatted"].each { |m| m["tool_calls"]&.each { |t| t["id"] = "s" if t["id"] == payload.dig("toolCallList", 0, "id") } }
    submit = submit_with(payload["artifact"])

    assert_equal [ "rejected", "customer_confirmation_required" ], [ submit.status, submit.code ]
    assert_equal [
      [ "caller turns since the last get_cart result: 0 (turn-taking only; not a yes)", true ],
      [ "caller began speaking 0.1 s after the submit was requested (1 later turn, not counted)", false ],
      [ "same model completion answered the get_cart result and issued this submit: yes", true ],
      [ "confirmation gate: submit refused (no caller turn after the read-back)", true ]
    ], shadow(submit).map { |o| [ o.text, o.warn ] }
    assert shadow(submit).none? { |o| o.text.match?(/confirmed by|customer confirmed|caller confirmed/i) }
  end

  test "a submit refused by the confirmation gate is obvious on the event row and the board" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("c", "get_cart")
    Voice::ToolRunner.call(call_log: CallLog.find(@call.id), artifact: VapiHistory.for_submit("s", caller_turns: 0, same_completion: true),
                           tool_call: { "id" => "s", "function" => { "name" => "submit_order", "arguments" => { "fulfillment_type" => "pickup", "cart_version" => 1 } } })
    refused = events.find { |e| e.invocation.tool_call_id == "s" }

    assert_equal "⛔ rejected · customer_confirmation_required", refused.badge
    assert_equal "confirmation required · submit refused (0 caller turns since the last get_cart; nothing was submitted, v1 kept)", refused.result_summary
    assert_includes shadow(refused).map(&:text), "confirmation gate: submit refused (no caller turn after the read-back)"
    assert_equal [ "CART OPEN", "submit refused: waiting for the caller's answer to the read-back (v1)" ], [ board.status_label, board.confirmation ]

    Voice::ToolRunner.call(call_log: CallLog.find(@call.id), artifact: VapiHistory.answered("s2"),
                           tool_call: { "id" => "s2", "function" => { "name" => "submit_order", "arguments" => { "fulfillment_type" => "pickup", "cart_version" => 1 } } })
    assert_match(/\Asubmitted v1 at /, board.confirmation)
    assert_includes shadow(events.find { |e| e.invocation.tool_call_id == "s2" }).map(&:text), "confirmation gate: passed (a caller turn followed the read-back)"
  end

  test "missing history on a refused submit says so instead of counting turns" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("c", "get_cart")
    Voice::ToolRunner.call(call_log: CallLog.find(@call.id),
                           tool_call: { "id" => "s", "function" => { "name" => "submit_order", "arguments" => { "fulfillment_type" => "pickup", "cart_version" => 1 } } })
    assert_equal "confirmation required · submit refused (no readable conversation history; nothing was submitted, v1 kept)",
                 events.find { |e| e.invocation.tool_call_id == "s" }.result_summary
  end

  test "a caller turn after the read-back and a later completion are not flagged" do
    artifact = { "messages" => [ { "role" => "tool_call_result", "name" => "get_cart", "toolCallId" => "c", "time" => 1 },
                                 { "role" => "user", "time" => 2 }, { "role" => "tool_calls", "time" => 3, "toolCalls" => [ { "id" => "s" } ] } ],
                 "messagesOpenAIFormatted" => [ { "role" => "tool", "tool_call_id" => "c" }, { "role" => "user" },
                                                { "role" => "assistant", "tool_calls" => [ { "id" => "s", "function" => { "name" => "submit_order" } } ] } ] }
    submit = submit_with(artifact)
    assert_equal [ [ "caller turns since the last get_cart result: 1 (turn-taking only; not a yes)", false ],
                   [ "same model completion answered the get_cart result and issued this submit: no", false ],
                   [ "confirmation gate: passed (a caller turn followed the read-back)", false ] ], shadow(submit).map { |o| [ o.text, o.warn ] }
  end

  test "missing history and rows recorded before the instrumentation say so" do
    assert_equal [ "turn evidence unavailable: the webhook carried no conversation history", true ], shadow(submit_with(nil)).first.then { |o| [ o.text, o.warn ] }

    ToolInvocation.find_by!(call_log_id: @call.id, tool_call_id: "s").update_columns(turn_evidence: nil)
    older = events.find { |e| e.invocation.tool_call_id == "s" }
    assert_match(/\Aturn evidence not recorded for this submit/, shadow(older).sole.text)
  end

  test "the ended row sits where the call really ended, not when Vapi's report arrived" do
    travel_to Time.zone.local(2026, 9, 30, 12, 0, 0) do
      @call.update!(started_at: Time.current)
      travel 90.seconds # the report arrives a minute and a half after the call started...
      CallLifecycle.finish(external_call_id: "view_1", transcript: nil, recording_url: nil, outcome: { duration_seconds: 30, ended_reason: "customer-ended-call" })
    end
    ended = ConsoleView::Timeline.new(CallLog.find(@call.id)).lifecycle_entries.find { |e| e.kind == :ended }
    assert_equal "00:30", ended.offset, "...but the call lasted 30 s"
  end
end

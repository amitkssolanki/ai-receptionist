require "test_helper"

class ConsoleViewTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(name: "View Bistro", phone_number: "+15550006464", business_hours: ALWAYS_OPEN_HOURS, timezone: "America/New_York")
    category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @cheese = @burger.menu_item_modifiers.create!(name: "Extra cheese", price_cents: 150)
    @call = CallLifecycle.start(external_call_id: "view_1", dialed_number: @restaurant.phone_number, caller_number: "unknown-view_1".then { nil })
  end

  def run_tool(id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(@call.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } })
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
      Voice::ToolRunner.call(call_log: other, tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } })
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
end

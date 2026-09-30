require "test_helper"
require "turbo/broadcastable/test_helper"

class ConsoleBroadcasterTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  SENSITIVE_ADDRESS = "77 SENSITIVE_STREET".freeze
  SENSITIVE_NOTE = "SENSITIVE_NOTE_TEXT".freeze
  PHONE = "+15557771234".freeze

  setup do
    @restaurant = Restaurant.create!(name: "Broadcast Bistro", phone_number: "+15550006363", business_hours: ALWAYS_OPEN_HOURS)
    category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @cheese = @burger.menu_item_modifiers.create!(name: "Extra cheese", price_cents: 150)
    @session_key = SecureRandom.hex(16)
    token = ConsoleToken.issue(restaurant: @restaurant, session_key: @session_key)
    @session_actions = capture_turbo_stream_broadcasts([ :console_session, @session_key ]) do
      @call = CallLifecycle.start(external_call_id: "bc_1", dialed_number: @restaurant.phone_number, caller_number: PHONE, console_token: token)
    end
    @log = StringIO.new
    @original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log)
  end

  teardown { Rails.logger = @original_logger }

  def stream = [ @call, :console ]

  def run_tool(id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(@call.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } })
  end

  def capture(&block) = capture_turbo_stream_broadcasts(stream, &block)
  def describe(actions) = actions.map { |a| [ a["action"], a["target"] ] }
  def html(actions) = actions.map(&:to_html).join("\n")
  def no_failures! = assert_no_match(/broadcast failed/, @log.string)

  # --- a call attaching to its console page ---

  test "when a console call starts, the page that issued its token is told, and only that page" do
    assert_equal [ [ "update", "console-call" ] ], describe(@session_actions)
    body = html(@session_actions)
    assert_includes body, "turbo-cable-stream-source"
    assert_includes body, "channel=\"ConsoleChannel\""
    assert_includes body, Rails.application.routes.url_helpers.admin_console_call_state_path(@call)
    assert_equal @session_key, @call.console_session_key
  end

  test "a call without a console session key announces nothing on any session stream" do
    actions = capture_turbo_stream_broadcasts([ :console_session, "f" * 32 ]) do
      CallLifecycle.start(external_call_id: "phone_call_1", dialed_number: @restaurant.phone_number, caller_number: "+15557772222")
    end
    assert_empty actions
  end

  test "starting a call also records a lifecycle row on the call's stream" do
    other_actions = capture_turbo_stream_broadcasts([ CallLog.find_by!(external_call_id: "bc_1"), :console ]) do
      ConsoleBroadcaster.lifecycle(@call, :started)
    end
    assert_includes describe(other_actions), [ "append", "events" ]
    assert_includes html(other_actions), "call started"
  end

  # --- tool calls: event row, then board, then status, in that order ---

  test "a tool call broadcasts its event row, then the order board, then the call status" do
    actions = capture { run_tool("tc_add", "add_to_cart", { "menu_item_id" => @burger.id, "modifier_ids" => [ @cheese.id ], "quantity" => 2 }) }

    assert_equal [ [ "append", "events" ], [ "replace", "order-board" ], [ "replace", "call-status" ] ], describe(actions)
    row = actions.first.to_html
    assert_includes row, "id=\"tool_call_tc_add\""
    assert_includes row, "add_to_cart"
    assert_includes row, "2× Burger"
    assert_includes row, "Extra cheese"
    assert_includes row, "v0 → v1"
    assert_includes row, "data-cart-changed=\"true\""
    no_failures!
  end

  test "the order board is an authoritative snapshot: lines, total, cart version, read-back and confirmation" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id, "modifier_ids" => [ @cheese.id ] })
    actions = capture { run_tool("c", "get_cart") }
    board = actions.find { |a| a["target"] == "order-board" }.to_html

    assert_includes board, "1 × Burger"
    assert_includes board, "+ Extra cheese"
    assert_includes board, "$11.50"
    assert_includes board, "v1"
    assert_match(/delivered for v1 at \d\d:\d\d:\d\d/, board)
    assert_includes board, "ready to submit (needs v1)"
    no_failures!
  end

  test "a change after the read-back is shown as STALE, straight from the server" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("c", "get_cart")
    actions = capture { run_tool("b", "add_to_cart", { "menu_item_id" => @burger.id }) }
    assert_includes actions.find { |a| a["target"] == "order-board" }.to_html, "STALE: cart v2, read-back v1"
  end

  test "the board and event rows show the observations from server facts" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    actions = capture do
      run_tool("b", "add_to_cart", { "menu_item_id" => @burger.id, "modifier_ids" => [ @cheese.id ] })
      run_tool("c", "get_cart")
      run_tool("s", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 })
    end
    text = html(actions)
    assert_includes text, "Burger is now on 2 lines of the cart"
    assert_includes text, "Burger is on 2 lines of the cart"
    assert_match(/\d+\.\d s since the last get_cart \(elapsed time only/, text)
    assert_includes text, "confirmation gate: shadow only (observed, nothing refused)"
    assert_no_match(/submitted \d+\.\d s after the last get_cart/, text)
    assert_includes text, "data-repeated-item"
    no_failures!
  end

  test "submit shows the confirmation, the lock and the SMS outcome" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("c", "get_cart")
    actions = capture { run_tool("s", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) }
    board = actions.find { |a| a["target"] == "order-board" }.to_html

    assert_includes board, "CONFIRMED"
    assert_match(/submitted v1 at \d\d:\d\d:\d\d/, board)
    assert_includes board, "confirmation text queued"
    assert_includes actions.first.to_html, "confirmed v1"
    no_failures!
  end

  test "a rejected tool call is shown as rejected with its code and the guidance the agent received" do
    actions = capture { run_tool("bad", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) }
    row = actions.first.to_html
    assert_includes row, "⛔ rejected · cart_empty"
    assert_includes row, "data-status=\"rejected\""
    assert_includes row, "The cart is empty"
    assert_includes row, "data-cart-changed=\"false\""
  end

  test "an unexpected failure shows internal_error only: no exception text reaches the page" do
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { |*, **| raise "leaky SENSITIVE_EXCEPTION_TEXT" }
    begin
      actions = capture { run_tool("boom", "add_to_cart", { "menu_item_id" => @burger.id }) }
    ensure
      Order.define_method(:recompute_total!, original)
    end
    text = html(actions)
    assert_includes text, "✖ internal_error"
    assert_no_match(/SENSITIVE_EXCEPTION_TEXT|RuntimeError/, text)
  end

  test "a replayed delivery replaces its row with the replay count; nothing is appended, no version moves" do
    run_tool("dup", "add_to_cart", { "menu_item_id" => @burger.id })
    actions = capture { run_tool("dup", "add_to_cart", { "menu_item_id" => @burger.id }) }

    assert_equal [ [ "replace", "tool_call_dup" ], [ "replace", "order-board" ], [ "replace", "call-status" ] ], describe(actions)
    assert_includes actions.first.to_html, "↺ replayed ×1"
    assert_includes actions.find { |a| a["target"] == "order-board" }.to_html, "v1"
    assert_includes actions.last.to_html, "duplicates absorbed ×1"
  end

  test "read-only tools without an order touch no board" do
    actions = capture { run_tool("menu", "get_menu") }
    assert_equal [ [ "append", "events" ], [ "replace", "call-status" ] ], describe(actions)
    assert_includes actions.first.to_html, "categories"
  end

  # --- lifecycle ---

  test "a transfer broadcasts a lifecycle row and the new status" do
    actions = capture { run_tool("x", "transfer_to_human", { "reason" => "wants a person" }) }
    text = html(actions)
    assert_includes describe(actions), [ "append", "events" ]
    assert_includes text, "transferred to a person: wants a person"
    assert_includes text, "TRANSFERRED"
  end

  test "ending the call broadcasts the ended row with reason, duration and cost, plus the abandoned board" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    actions = capture do
      CallLifecycle.finish(external_call_id: "bc_1", transcript: "AI: bye", recording_url: nil,
                           outcome: { ended_reason: "customer-ended-call", duration_seconds: 95.2, cost: 0.1234 })
    end
    text = html(actions)
    assert_includes text, "call ended · customer-ended-call · 95s · $0.1234"
    assert_includes actions.find { |a| a["target"] == "order-board" }.to_html, "ABANDONED"
    assert_includes text, "ABANDONED"
  end

  test "lifecycle and tool rows share one events list and carry stable DOM ids" do
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    ids = capture { CallLifecycle.transfer(CallLog.find(@call.id), "r") }.map(&:to_html).join.scan(/id="(lifecycle_\d+_\w+)"/).flatten
    assert_equal [ "lifecycle_#{@call.id}_transferred" ], ids
  end

  # --- safety ---

  test "nothing sensitive is broadcast: no address, no free-text notes, no phone number, no secrets, no raw payloads" do
    ENV["VAPI_SERVER_SECRET"] = "0123456789abcdef0123456789abcdef"
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id, "notes" => SENSITIVE_NOTE })
    run_tool("c", "get_cart")
    actions = capture do
      run_tool("a2", "add_to_cart", { "menu_item_id" => @burger.id, "notes" => SENSITIVE_NOTE })
      run_tool("c2", "get_cart")
      run_tool("s", "submit_order", { "fulfillment_type" => "delivery", "cart_version" => 2, "delivery_address" => SENSITIVE_ADDRESS, "notes" => SENSITIVE_NOTE })
      run_tool("x", "transfer_to_human", { "reason" => "asked about SENSITIVE_REASON_OK" })
    end
    text = html(actions)

    assert_no_match(/SENSITIVE_STREET|SENSITIVE_NOTE_TEXT|#{Regexp.escape(PHONE)}|1234\b.*unknown|0123456789abcdef|X-Vapi-Secret|listenUrl|controlUrl|webCallUrl/, text)
    assert_includes text, "notes: #{SENSITIVE_NOTE.length} chars"
    assert_includes text, "address given"
    assert_includes text, "delivery (address on file)"
  ensure
    ENV.delete("VAPI_SERVER_SECRET")
  end

  test "a broadcasting failure is contained: the tool answer is unchanged and only the class is logged" do
    expected = run_tool("ok", "get_menu")
    original = Turbo::StreamsChannel.method(:broadcast_append_to)
    Turbo::StreamsChannel.define_singleton_method(:broadcast_append_to) { |*, **| raise "cable down SENSITIVE_CABLE_TEXT" }
    begin
      assert_equal expected, run_tool("also_ok", "get_menu")
    ensure
      Turbo::StreamsChannel.define_singleton_method(:broadcast_append_to, original)
    end
    assert_match(/\[Console\] broadcast failed: RuntimeError/, @log.string)
    assert_no_match(/SENSITIVE_CABLE_TEXT/, @log.string)
    assert_equal 2, @call.tool_invocations.count, "the audit rows are committed regardless"
  end

  test "broadcasts happen after the commit, never for a rolled-back tool call" do
    actions = capture do
      ApplicationRecord.transaction do
        run_tool("rb", "add_to_cart", { "menu_item_id" => @burger.id })
        raise ActiveRecord::Rollback
      end
    end
    assert_empty actions.select { |a| a["target"] == "events" }, "rolled back: no row should reach any browser"
  end
end

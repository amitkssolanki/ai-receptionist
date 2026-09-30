require "test_helper"
require "turbo/broadcastable/test_helper"

# Reconnect / refresh: the browser rebuilds the server panels from the database, so a missed live broadcast never
# leaves the page wrong, and what it rebuilds equals what the live stream would have delivered.
class Admin::ConsoleBackfillTest < ActionDispatch::IntegrationTest
  include Turbo::Broadcastable::TestHelper

  setup do
    @restaurant = Restaurant.create!(name: "Backfill Bistro", phone_number: "+15550007171", business_hours: ALWAYS_OPEN_HOURS)
    @burger = @restaurant.menu_categories.create!(name: "Mains", position: 1).menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @user = User.create!(email: "backfill@example.com", password: "password123", restaurant: @restaurant)
    @session_key = SecureRandom.hex(16)
    token = ConsoleToken.issue(restaurant: @restaurant, session_key: @session_key)
    @call = CallLifecycle.start(external_call_id: "bf_1", dialed_number: @restaurant.phone_number, caller_number: "+15557774444", console_token: token)
  end

  # submit_order carries a history in which the caller answered the read-back (the confirmation gate's input, see
  # VapiHistory); the gate itself is tested in test/controllers/api/vapi/confirmation_gate_test.rb.
  def run_tool(id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(@call.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } },
                           artifact: VapiHistory.for_tool(name, id))
  end

  def script!
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id, "quantity" => 2 })
    run_tool("c", "get_cart")
    run_tool("bad", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 9 })
    run_tool("s", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })
    run_tool("s", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) # duplicate delivery
    CallLifecycle.finish(external_call_id: "bf_1", transcript: "AI: bye", recording_url: nil, outcome: { ended_reason: "customer-ended-call", duration_seconds: 60, cost: 0.1 })
  end

  test "the state frame renders status, order board and ordered events from the database alone" do
    script!
    sign_in @user
    get admin_console_call_state_path(@call)
    assert_response :success

    assert_select "turbo-frame#call-state #call-status", text: /COMPLETED/
    assert_select "turbo-frame#call-state #order-board", text: /CONFIRMED/
    assert_select "turbo-frame#call-state #order-board", text: /2 × Burger/
    assert_select "turbo-frame#call-state #order-board", text: /\$20\.00/
    assert_select "turbo-frame#call-events #events > div[data-server-row]", count: 6 # 4 tool calls (the duplicate delivery replays its row) + call started + call ended
    tools = css_select("#events [data-tool]").map { |row| [ row["data-tool"], row["data-status"] ] }
    assert_equal [ %w[add_to_cart ok], %w[get_cart ok], %w[submit_order rejected], %w[submit_order ok] ], tools
    assert_select "#events", text: /↺ replayed ×1/
    assert_select "#events", text: /call ended · customer-ended-call · 60s/
    assert_select "#events", text: /cart_changed_since_readback/
  end

  test "what the state frame rebuilds equals what the live stream delivered" do
    live = capture_turbo_stream_broadcasts([ @call, :console ]) { script! }
    live_ids = live.map { |action| action.to_html.scan(/id="((?:tool_call|lifecycle)_[^"]+)"/).flatten.first }.compact.uniq.sort

    sign_in @user
    get admin_console_call_state_path(@call)
    rebuilt_ids = css_select("#events [data-server-row]").map { |row| row["id"] }.sort
    assert_equal (live_ids + [ "lifecycle_#{@call.id}_started" ]).sort, rebuilt_ids # the started row was broadcast before the capture began

    live_board = live.select { |a| a["target"] == "order-board" }.last.at_css("#order-board").text.squish
    assert_equal live_board, css_select("#order-board").first.text.squish, "the last board broadcast is the same snapshot the page reloads"
  end

  test "events missed while disconnected are present after a reload, in time order" do
    sign_in @user
    run_tool("a", "add_to_cart", { "menu_item_id" => @burger.id })
    get admin_console_call_state_path(@call)
    assert_equal [ "lifecycle_#{@call.id}_started", "tool_call_a" ], css_select("#events [data-server-row]").map { |row| row["id"] }

    run_tool("c", "get_cart") # broadcast while "offline": this page never received it
    get admin_console_call_state_path(@call)
    assert_equal [ "lifecycle_#{@call.id}_started", "tool_call_a", "tool_call_c" ], css_select("#events [data-server-row]").map { |row| row["id"] }
  end

  test "the state endpoint serves only the signed-in user's restaurant" do
    other = Restaurant.create!(name: "Other", phone_number: "+15550007272")
    theirs = other.call_logs.create!(external_call_id: "theirs", customer: other.customers.create!(phone_number: "unknown-theirs"), phone_number: "unknown-theirs")

    sign_in @user
    get admin_console_call_state_path(theirs)
    assert_response :not_found
  end

  test "another restaurant's call page is not found either" do
    other = Restaurant.create!(name: "Other 2", phone_number: "+15550007373")
    theirs = other.call_logs.create!(external_call_id: "theirs2", customer: other.customers.create!(phone_number: "unknown-theirs2"), phone_number: "unknown-theirs2")
    sign_in @user
    get admin_console_call_path(theirs)
    assert_response :not_found
  end

  test "the state endpoint and call page require sign-in" do
    get admin_console_call_state_path(@call)
    assert_redirected_to new_user_session_path
    get admin_console_call_path(@call)
    assert_redirected_to new_user_session_path
  end

  test "the review page subscribes to the call stream and loads its state frames" do
    script!
    sign_in @user
    get admin_console_call_path(@call)
    assert_response :success
    assert_select "turbo-cable-stream-source[channel=ConsoleChannel]", count: 1
    assert_select "turbo-frame#call-state[src='#{admin_console_call_state_path(@call)}']"
    assert_select "turbo-frame#call-events[src='#{admin_console_call_state_path(@call)}']"
    assert_select "[data-controller~=console-sync]"
    assert_match(/not authoritative/, response.body)
  end

  test "the console page has the session stream and empty server panels, and no call data" do
    ENV["VAPI_PUBLIC_KEY"] = "pk-test-public-0000"
    ENV["VAPI_DEV_ASSISTANT_ID"] = "11111111-2222-3333-4444-555555555555"
    sign_in @user
    get admin_console_path
    assert_select "turbo-cable-stream-source[channel=ConsoleChannel]", count: 1
    assert_select "#console-call turbo-frame#call-state", text: /Waiting for a call/
    assert_select "#console-call turbo-frame#call-events"
    assert_select "[data-console-sync-claim-patterns-value]"
    patterns = JSON.parse(css_select("[data-console-sync-claim-patterns-value]").first["data-console-sync-claim-patterns-value"])
    assert_equal ClaimDetector::PATTERNS.keys, patterns.map { |p| p["kind"] }
  ensure
    ENV.delete("VAPI_PUBLIC_KEY")
    ENV.delete("VAPI_DEV_ASSISTANT_ID")
  end
end

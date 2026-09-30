# Step 0 (Phase 1): runnable copy of the frozen Phase 0 file
# test/fixtures/files/baseline/reliability_characterization_test.rb.frozen. This copy is part of the live suite
# and is expected to flip/evolve with Phase 1 (R-IDs kept); the frozen original is never edited (see
# baseline:verify). Content below is otherwise identical to the original.
# Phase 0 baseline: characterization tests for portfolio-baseline (257a9e7).
#
# These assert what the system CURRENTLY does - including unsafe behavior - so the baseline is
# reproducible. They are expected to start failing once Phase 1 changes the behavior; that flip is the
# before/after evidence. Nothing here modifies the project: the file lives outside the repo and runs
# against the transactional test database.
#
#   bin/rails test <path-to-this-file>
#
# Each test appends an observation row; they are written to BASELINE_OUT (JSON) at exit.
require "test_helper"
require "json"

module BaselineObservations
  ROWS = []
  def self.record(**row) = ROWS << row
  Minitest.after_run do
    out = ENV["BASELINE_OUT"]
    File.write(out, JSON.pretty_generate(ROWS.sort_by { |r| r[:id] })) if out
  end
end

class FakeTwilio
  attr_reader :sent
  def initialize = @sent = []
  def messages = self
  def create(**args) = @sent << args
end

class BaselineReliabilityTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ENV["VAPI_SERVER_SECRET"] = "test-vapi-secret"
    ENV["VOICE_WEBHOOK_SECRET"] = "test-secret"

    # Phase 1 Step 4: was "00:00-23:59" (the seeded shape); closed-hours enforcement makes the last minute matter.
    @restaurant = Restaurant.create!(name: "Baseline Pizzeria", phone_number: "+15550001111", business_hours: ALWAYS_OPEN_HOURS)
    pizzas = @restaurant.menu_categories.create!(name: "Pizzas", position: 1)
    sides = @restaurant.menu_categories.create!(name: "Sides", position: 2)
    mains = @restaurant.menu_categories.create!(name: "Mains", position: 3)
    @margherita = pizzas.menu_items.create!(restaurant: @restaurant, name: "Margherita Pizza", price_cents: 1400)
    @extra_cheese = @margherita.menu_item_modifiers.create!(name: "Extra cheese", price_cents: 200)
    @knots = sides.menu_items.create!(restaurant: @restaurant, name: "Garlic Knots", price_cents: 550)
    @burger = mains.menu_items.create!(restaurant: @restaurant, name: "Bistro Burger", price_cents: 1300)
    @bacon = @burger.menu_item_modifiers.create!(name: "Add bacon", price_cents: 200)
    @sold_out = mains.menu_items.create!(restaurant: @restaurant, name: "Sold Out Special", price_cents: 900, available: false)
    @margherita.menu_item_upsells.create!(upsell_item: @knots)

    @seq = 0
  end

  teardown do
    ENV.delete("VAPI_SERVER_SECRET")
    ENV.delete("VOICE_WEBHOOK_SECRET")
    %w[TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_FROM_NUMBER].each { |k| ENV.delete(k) }
  end

  # --- Vapi-shaped helpers (same payload shapes as the live calls) ---

  def vapi(message)
    post api_vapi_webhooks_path, params: { message: message }, headers: { "X-Vapi-Secret" => "test-vapi-secret" }, as: :json
  end

  def start_call(id = "call_baseline")
    # Browser web call: no customer number, matching both live calls.
    vapi(type: "status-update", status: "in-progress", call: { id: id, type: "webCall" })
    CallLog.find_by(external_call_id: id)
  end

  def tool(call_id, name, args = {}, tool_call_id: "tc_#{@seq += 1}")
    vapi(type: "tool-calls", call: { id: call_id }, toolCallList: [ { id: tool_call_id, type: "function", function: { name: name, arguments: args } } ])
    JSON.parse(response.body)["results"].first["result"]
  end

  def cart(call_id) = JSON.parse(tool(call_id, "get_cart"))

  # Step 5: submit_order needs the cart_version of the server's read-back (get_cart).
  def submit(call_id, args = { fulfillment_type: "pickup" }) = tool(call_id, "submit_order", args.merge(cart_version: cart(call_id)["cart_version"]))

  def rec(**row) = BaselineObservations.record(**row)

  # Phase 1 Step 3: failures are {"ok":false,"error":{"code","message"}}; returns [code, message].
  def error_of(result)
    error = JSON.parse(result)["error"]
    [ error["code"], error["message"] ]
  end

  # Nothing the model is told may contain exception text, SQL or class names.
  LEAK_PATTERN = /Sorry, something went wrong|ActiveRecord|undefined method|key not found|Validation failed|Couldn't find|NoMethodError|SELECT |Traceback|\.rb:\d+|Error\b/

  def assert_no_leak(result)
    assert_no_match LEAK_PATTERN, result
  end

  # --- Confirmation / order lifecycle ---

  test "R01 submit_order is refused until the server has read the current cart back" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    result = tool(c.external_call_id, "submit_order", { fulfillment_type: "pickup", cart_version: 1 })

    assert_equal "readback_required", error_of(result).first
    assert_no_leak result
    assert c.reload.order.pending?, "status unchanged"
    assert_equal 0, enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }

    assert_equal "invalid_arguments", error_of(tool(c.external_call_id, "submit_order", { fulfillment_type: "pickup" })).first # version is required
    assert_nil JSON.parse(submit(c.external_call_id))["error"]
    assert c.reload.order.confirmed?
    rec(id: "R01", scenario: "Submit without read-back", layer: "vapi",
        current: "Step 5: refused with readback_required until get_cart has read back the current cart_version; missing cart_version -> invalid_arguments. Refusal: #{result}",
        safe: "Reject unless the cart was read back (via server) after the last change")
  end

  test "R02 submitting twice re-confirms, moves placed_at, and enqueues a second SMS" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    submit(c.external_call_id)
    first_placed = c.reload.order.placed_at
    travel 1.minute do
      submit(c.external_call_id, { fulfillment_type: "delivery", delivery_address: "1 Main St" })
    end
    order = c.reload.order

    assert_equal 2, enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }
    assert_not_equal first_placed, order.placed_at
    assert order.delivery?
    rec(id: "R02", scenario: "Submit twice", layer: "vapi",
        current: "Second submit accepted: 2 OrderConfirmationSmsJob enqueued, placed_at overwritten, fulfillment switched pickup->delivery on an already-confirmed order",
        safe: "Idempotent: second submit returns the existing confirmation; no second SMS; no field changes")
  end

  test "R03 a submitted order can no longer be changed by voice tools (confirmed, or after the kitchen moves on)" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    submit(c.external_call_id)
    order = c.reload.order
    item_id = order.order_items.sole.id

    attempts = lambda do
      [ tool(c.external_call_id, "add_to_cart", { menu_item_id: @knots.id }),
        tool(c.external_call_id, "update_cart_item_quantity", { order_item_id: item_id, quantity: 3 }),
        tool(c.external_call_id, "remove_cart_item", { order_item_id: item_id }) ]
    end
    (attempts.call + (order.update!(status: :preparing) && attempts.call)).each do |r|
      assert_equal "order_already_submitted", error_of(r).first
      assert_no_leak r
    end
    order.reload

    assert order.preparing?
    assert_equal [ "Margherita Pizza" ], order.order_items.map { |i| i.menu_item.name }
    assert_equal 1400, order.total_cents
    rec(id: "R03", scenario: "Modify order after submission", layer: "vapi",
        current: "Step 4: add/update/remove are refused with order_already_submitted (confirmed and preparing); items and total unchanged at 1400 cents",
        safe: "Reject cart mutations once the order is submitted")
  end

  # --- Input validation ---

  test "R04 a modifier belonging to another item is rejected, naming the valid options" do
    c = start_call
    result = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, modifier_ids: [ @bacon.id ] })

    code, message = error_of(result)
    assert_equal "invalid_modifier", code
    assert_includes message, "Extra cheese"
    assert_no_leak result
    assert_nil c.reload.order, "nothing inserted"
    rec(id: "R04", scenario: "Invalid modifier (belongs to another item)", layer: "vapi",
        current: "Step 4: rejected with invalid_modifier listing the item's valid modifiers; nothing inserted (#{result})",
        safe: "Reject with an actionable error naming the valid modifiers")
  end

  test "R05 a nonexistent modifier id is rejected and nothing is inserted" do
    c = start_call
    result = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, modifier_ids: [ @extra_cheese.id, 999_999 ] })

    assert_equal "invalid_modifier", error_of(result).first
    assert_match(/999999/, error_of(result).last)
    assert_nil c.reload.order
    rec(id: "R05", scenario: "Invalid modifier (nonexistent id)", layer: "vapi",
        current: "Step 4: rejected with invalid_modifier, even when mixed with a valid one; nothing inserted",
        safe: "Reject with an actionable error")
  end

  def create_other_restaurant_item
    other = Restaurant.create!(name: "Other Place", phone_number: "+15550002222")
    other.menu_categories.create!(name: "X", position: 1).menu_items.create!(restaurant: other, name: "Foreign Item", price_cents: 100)
  end

  test "R06 unknown, unavailable and foreign menu items are rejected with a structured, speakable code" do
    c = start_call
    @foreign_item = create_other_restaurant_item # created after call start; see R23 for why
    unknown = tool(c.external_call_id, "add_to_cart", { menu_item_id: 999_999 })
    sold_out = tool(c.external_call_id, "add_to_cart", { menu_item_id: @sold_out.id })
    foreign = tool(c.external_call_id, "add_to_cart", { menu_item_id: @foreign_item.id })

    [ unknown, sold_out, foreign ].each do |r|
      assert_equal "menu_item_unavailable", error_of(r).first
      assert_no_leak r
    end
    assert_nil c.reload.order
    rec(id: "R06", scenario: "Invalid / unavailable / other-restaurant menu item", layer: "vapi",
        current: "Not inserted. Step 3: structured error code menu_item_unavailable with guidance, no exception text, e.g. #{unknown.inspect}",
        safe: "Not inserted, with a structured, speakable error code (e.g. item_unavailable)")
  end

  test "R07 quantity must be a whole number from 1 to 20; more than 30 items needs staff" do
    c = start_call
    accepted = [ 1, 20 ].map { |q| JSON.parse(tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, quantity: q })) }
    assert accepted.none? { |r| r.key?("error") }

    [ 0, 21, -3, 500 ].each do |q|
      result = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, quantity: q })
      assert_equal "quantity_out_of_range", error_of(result).first, "quantity #{q}"
    end
    [ "two", 2.5 ].each do |q|
      result = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, quantity: q })
      assert_equal "invalid_arguments", error_of(result).first, "quantity #{q.inspect}"
    end
    order = c.reload.order
    assert_equal [ 1, 20 ], order.order_items.map(&:quantity)
    assert_equal 21 * 1400, order.total_cents

    # 21 items so far: 9 more reaches exactly 30, one more is too many.
    assert_nil JSON.parse(tool(c.external_call_id, "add_to_cart", { menu_item_id: @knots.id, quantity: 9 }))["error"]
    over = tool(c.external_call_id, "add_to_cart", { menu_item_id: @knots.id })
    assert_equal "large_order_requires_staff", error_of(over).first
    assert_equal 30, order.reload.order_items.sum(:quantity)
    rec(id: "R07", scenario: "Excessive / invalid quantity", layer: "vapi",
        current: "Step 4: 1-20 per line accepted; 0, -3, 21, 500 -> quantity_out_of_range; \"two\"/2.5 -> invalid_arguments; total item count capped at 30 (large_order_requires_staff)",
        safe: "Upper bound; large orders routed to a human (the prompt's 'large order -> transfer' rule enforced server-side)")
  end

  test "R08 orders are refused while the restaurant is closed, with today's hours" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id }) # open: accepted
    @restaurant.update!(business_hours: %w[sun mon tue wed thu fri sat].index_with { "closed" })
    add = tool(c.external_call_id, "add_to_cart", { menu_item_id: @knots.id })
    submit = submit(c.external_call_id)

    assert_not @restaurant.reload.open_now?
    [ add, submit ].each do |r|
      assert_equal "restaurant_closed", error_of(r).first
      assert_match(/closed today/, error_of(r).last)
    end
    assert c.reload.order.pending?
    assert_equal 1, c.order.order_items.count

    @restaurant.update!(business_hours: %w[sun mon tue wed thu fri sat].index_with { "11:00-21:00" })
    travel_to ActiveSupport::TimeZone[@restaurant.timezone].local(2026, 9, 30, 15, 0) do
      assert_nil JSON.parse(submit(c.external_call_id))["error"]
    end
    assert c.order.reload.confirmed?
    rec(id: "R08", scenario: "Order while restaurant closed", layer: "vapi",
        current: "Step 4: add_to_cart and submit_order refused with restaurant_closed + today's hours; the cart is kept and submit works once open",
        safe: "Reject submission when closed, with a speakable reason")
  end

  test "R09 24-hour days are open all day, including the last minute" do
    tz = ActiveSupport::TimeZone[@restaurant.timezone]
    [ "24h", "00:00-24:00" ].each do |hours|
      @restaurant.update!(business_hours: %w[sun mon tue wed thu fri sat].index_with { hours })
      assert @restaurant.open_now?(at: tz.local(2026, 9, 30, 0, 0, 0)), hours
      assert @restaurant.open_now?(at: tz.local(2026, 9, 30, 23, 59, 30)), hours
      assert @restaurant.open_now?(at: tz.local(2026, 9, 30, 23, 59, 59)), hours
    end
    # The old shape still closes for its last minute; the seeds now use 00:00-24:00.
    @restaurant.update!(business_hours: %w[sun mon tue wed thu fri sat].index_with { "00:00-23:59" })
    assert_not @restaurant.open_now?(at: tz.local(2026, 9, 30, 23, 59, 30))
    rec(id: "R09", scenario: "24/7 hours edge (seed data)", layer: "model",
        current: "Step 4: '24h' and '00:00-24:00' are open all day; seeds use 00:00-24:00. A literal '00:00-23:59' still closes at 23:59:01",
        safe: "A real 24-hour representation (or document the one-minute gap)")
  end

  # --- Malformed arguments / raw exceptions ---

  test "R10 malformed tool arguments are refused at the boundary with structured errors" do
    c = start_call
    missing = tool(c.external_call_id, "add_to_cart", {})
    bad_json = begin
      vapi(type: "tool-calls", call: { id: c.external_call_id },
           toolCallList: [ { id: "tc_bad", type: "function", function: { name: "add_to_cart", arguments: "{not json" } } ])
      JSON.parse(response.body)["results"].first["result"]
    end
    no_cart_update = tool(c.external_call_id, "update_cart_item_quantity", { order_item_id: 1, quantity: 2 })
    bad_enum = begin
      tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
      tool(c.external_call_id, "submit_order", { fulfillment_type: "teleport" })
    end
    no_address = tool(c.external_call_id, "submit_order", { fulfillment_type: "delivery", cart_version: 1 })

    assert_equal "invalid_arguments", error_of(missing).first
    assert_match(/menu_item_id is required/, error_of(missing).last)
    assert_equal "invalid_arguments", error_of(bad_json).first
    assert_match(/not valid JSON/, error_of(bad_json).last)
    assert_equal "cart_empty", error_of(no_cart_update).first
    assert_equal "invalid_arguments", error_of(bad_enum).first
    assert_match(/fulfillment_type must be one of: pickup, delivery/, error_of(bad_enum).last)
    assert_equal "delivery_address_required", error_of(no_address).first
    [ missing, bad_json, no_cart_update, bad_enum, no_address ].each { |r| assert_no_leak r }
    rec(id: "R10", scenario: "Malformed tool arguments / raw exception exposure", layer: "vapi",
        current: "Step 3: validated by Voice::ToolArguments before any service runs; structured errors, no exception text: #{[ missing, bad_json, no_cart_update, bad_enum ].map(&:inspect).join(' | ')}",
        safe: "Validate arguments at the boundary; return structured error codes; never expose exception text")
  end

  test "R11 tool call for an unknown call, and an unknown tool name" do
    unknown_call = tool("no_such_call", "get_menu")
    c = start_call
    unknown_tool = tool(c.external_call_id, "delete_everything")

    assert_equal "no_active_call", error_of(unknown_call).first
    assert_equal "unknown_tool", error_of(unknown_tool).first
    [ unknown_call, unknown_tool ].each { |r| assert_no_leak r }
    rec(id: "R11", scenario: "Unknown call id / unknown tool", layer: "vapi",
        current: "Step 3: structured errors no_active_call / unknown_tool (#{unknown_call.inspect}, #{unknown_tool.inspect}); HTTP 200",
        safe: "Already safe; keep")
  end

  # --- Lifecycle events ---

  test "R12 end-of-call-report overwrites a transferred call's status" do
    c = start_call
    tool(c.external_call_id, "transfer_to_human", { reason: "caller asked for a person" })
    assert c.reload.transferred?
    vapi(type: "end-of-call-report", call: { id: c.external_call_id }, artifact: { transcript: "AI: hi" })

    assert c.reload.abandoned?
    assert_includes c.transcript.to_s, "AI: hi"
    assert_not_includes c.transcript.to_s, "Transferred to human"
    rec(id: "R12", scenario: "Transferred call followed by end-of-call", layer: "vapi",
        current: "Status transferred -> abandoned; the '[Transferred to human: ...]' note is also overwritten by the report's transcript",
        safe: "Preserve transferred status and the transfer note")
  end

  test "R13 duplicate call-start: sequential duplicate is ignored, check-then-create race returns 422" do
    c = start_call("dup_call")
    start_call("dup_call")
    assert_equal 1, CallLog.where(external_call_id: "dup_call").count

    # Simulate the race window: a second request passes the exists? check before the first commits.
    original = CallLog.method(:exists?)
    CallLog.define_singleton_method(:exists?) { |*| false }
    begin
      vapi(type: "status-update", status: "in-progress", call: { id: "dup_call", type: "webCall" })
    ensure
      CallLog.singleton_class.send(:remove_method, :exists?)
    end
    assert_equal original.call(external_call_id: "dup_call"), true
    assert_response :unprocessable_entity
    rec(id: "R13", scenario: "Duplicate call-start event", layer: "vapi",
        current: "Sequential duplicate: ignored (1 CallLog). Racing duplicate: CallLog.create! raises uniqueness RecordInvalid -> HTTP #{response.status}",
        safe: "Create-or-find; always 200 for a duplicate start")
    assert c
  end

  test "R14 the same tool-call id delivered twice executes once and returns the stored result" do
    c = start_call
    first = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id }, tool_call_id: "call_same")
    second = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id }, tool_call_id: "call_same")

    assert_equal first, second
    assert_equal 1, c.reload.order.order_items.count
    assert_equal 1400, c.order.total_cents
    assert_equal 1, c.order.cart_version
    assert_equal [ 1, 1 ], [ c.tool_invocations.count, c.tool_invocations.sole.replay_count ]
    rec(id: "R14", scenario: "Duplicate tool call (same toolCallId redelivered)", layer: "vapi",
        current: "Step 7: the duplicate is answered from the stored ToolInvocation result: one order item (1400 cents), cart_version 1, replay_count 1",
        safe: "Replay of a toolCallId returns the stored result without re-executing")
  end

  test "R15 two add_to_cart calls in one toolCallList both execute" do
    c = start_call
    vapi(type: "tool-calls", call: { id: c.external_call_id }, toolCallList: [
      { id: "p1", type: "function", function: { name: "add_to_cart", arguments: { menu_item_id: @margherita.id } } },
      { id: "p2", type: "function", function: { name: "add_to_cart", arguments: { menu_item_id: @margherita.id } } }
    ])

    assert_equal 2, JSON.parse(response.body)["results"].size
    assert_equal 2, c.reload.order.order_items.count
    rec(id: "R15", scenario: "Parallel duplicate tool calls (distinct ids, same intent)", layer: "vapi",
        current: "Both executed -> 2 items. Indistinguishable from a caller ordering two",
        safe: "Not solvable by idempotency; caught by server-owned read-back before submit")
  end

  test "R16 add_to_cart is atomic: a failed item insert leaves no order and no call link" do
    c = start_call
    original = OrderItem.instance_method(:save!)
    OrderItem.define_method(:save!) { |*| raise ActiveRecord::StatementInvalid, "simulated failure" }
    begin
      result = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    ensure
      OrderItem.define_method(:save!, original)
    end
    c.reload

    assert_equal "internal_error", error_of(result).first
    assert_no_leak result
    assert_nil c.order, "no order is linked to the call"
    assert_equal 0, Order.count
    rec(id: "R16", scenario: "Partial failure inside add_to_cart", layer: "vapi",
        current: "Step 4: order creation, call link, item and total commit together; after a failed insert no order exists; LLM got #{result.inspect}",
        safe: "Single transaction; nothing persisted on failure")
  end

  test "R17 a call that ends with an unsubmitted cart marks the order abandoned (items kept)" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    vapi(type: "end-of-call-report", call: { id: c.external_call_id }, artifact: { transcript: "AI: bye" })

    assert c.reload.abandoned?
    assert c.order.abandoned?
    assert_equal 1, c.order.order_items.count
    assert_equal 1400, c.order.total_cents
    rec(id: "R17", scenario: "Abandoned call with unsubmitted cart", layer: "vapi",
        current: "Step 4: CallLog abandoned and its order moves pending -> abandoned with items and total kept",
        safe: "Mark the cart abandoned/cancelled at end of call")
  end

  test "R23 a call with no dialed number is silently dropped once a second restaurant exists" do
    create_other_restaurant_item
    c = start_call("orphan_call")
    menu = tool("orphan_call", "get_menu")

    assert_nil c
    assert_response :success
    assert_equal "no_active_call", error_of(menu).first
    rec(id: "R23", scenario: "Restaurant resolution for web calls (no dialed number)", layer: "vapi",
        current: "Works only while exactly one Restaurant exists (Restaurant.count == 1 fallback). With two, no CallLog is created (HTTP 200, warning log only) and every tool returns 'No active call found'",
        safe: "Explicit restaurant resolution (e.g. assistant metadata) and a loud failure; documented single-tenant assumption")
  end

  # --- SMS ---

  test "R18 SMS: no-op without Twilio config; with config it texts a synthetic caller id and is not itemized" do
    c = start_call("sms_call")
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, modifier_ids: [ @extra_cheese.id ] })
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @knots.id })
    submit(c.external_call_id)
    order_id = c.reload.order.id

    assert_nothing_raised { OrderConfirmationSmsJob.perform_now(order_id) } # env unset -> returns early

    ENV["TWILIO_ACCOUNT_SID"] = "AC_test"
    ENV["TWILIO_AUTH_TOKEN"] = "token"
    ENV["TWILIO_FROM_NUMBER"] = "+15550009999"
    fake = FakeTwilio.new
    Twilio::REST::Client.singleton_class.send(:alias_method, :__baseline_new, :new)
    Twilio::REST::Client.define_singleton_method(:new) { |*| fake }
    begin
      OrderConfirmationSmsJob.perform_now(order_id)
    ensure
      Twilio::REST::Client.singleton_class.send(:alias_method, :new, :__baseline_new)
    end

    sent = fake.sent.first
    assert_equal "unknown-sms_call", sent[:to]
    assert_equal "Thanks for your order at Baseline Pizzeria! Total: $21.50. We'll have it ready soon.", sent[:body]
    rec(id: "R18", scenario: "SMS confirmation behavior", layer: "job",
        current: "Twilio unset: silent no-op. Twilio set: sends to #{sent[:to].inspect} (web-call placeholder, not a phone number); body #{sent[:body].inspect} - total only, no items",
        safe: "Skip non-phone caller ids; itemized body; record send status on the order")
  end

  # --- Boundary properties that are already safe (kept for the before/after table) ---

  test "R19 the LLM cannot set prices: extra price arguments are ignored" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, unit_price_cents: 1, price: 0.01, total: 0 })

    assert_equal 1400, c.reload.order.order_items.last.unit_price_cents
    assert_equal 1400, c.order.total_cents
    rec(id: "R19", scenario: "Price/total injection via tool arguments", layer: "vapi",
        current: "Ignored; unit price from the menu, total recomputed server-side",
        safe: "Already safe; keep")
  end

  test "R20 webhook authentication" do
    post api_vapi_webhooks_path, params: { message: { type: "status-update" } }, as: :json
    missing = response.status
    post api_vapi_webhooks_path, params: { message: { type: "status-update" } }, headers: { "X-Vapi-Secret" => "wrong" }, as: :json

    assert_equal 401, missing
    assert_response :unauthorized
    rec(id: "R20", scenario: "Webhook authentication", layer: "vapi",
        current: "Missing/wrong X-Vapi-Secret -> 401 (constant-time compare; static shared secret, no signature or timestamp)",
        safe: "Already adequate for a static secret over TLS; replay protection absent")
  end

  # --- R21 / R22: RETIRED in Phase 1 Step 2 ---
  #
  # Reason: R21 and R22 characterized the generic REST adapter (api/voice/*), which had no live consumer - Vapi
  # only ever called the webhook. Phase 1 deleted that adapter rather than keep two adapters in sync
  # (docs/phase1/PLAN.md, revision 2, "Generic REST adapter"). Nothing is left to characterize there.
  # The rules those tests pointed at are covered on the Vapi path: R02 (double submit), R03 (modify after
  # submit), R04 (foreign modifier) and R12 (transfer precedence). The frozen originals are still exercised,
  # against the tag, by `bin/rails baseline:verify`.
  RETIRED_REASON = "Retired in Phase 1 Step 2: the generic api/voice adapter was deleted (no live consumer); " \
                   "its rules are covered on the Vapi path by R02/R03/R04/R12".freeze

  test "R21 generic api/voice layer: same submit-twice, modify-after-submit and silent-modifier gaps" do
    skip RETIRED_REASON
  end

  test "R22 generic end_call also overwrites transferred status" do
    skip RETIRED_REASON
  end

  test "the generic api/voice adapter no longer exists" do
    [ [ :post, "/api/voice/calls" ], [ :get, "/api/voice/calls/x/menu" ], [ :post, "/api/voice/calls/x/submit" ],
      [ :post, "/api/voice/calls/x/cart_items" ] ].each do |verb, path|
      assert_raises(ActionController::RoutingError, "#{verb} #{path}") { Rails.application.routes.recognize_path(path, method: verb) }
    end
    assert_not defined?(Api::Voice), "Api::Voice should be gone"
  end
end

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

    all_day = %w[sun mon tue wed thu fri sat].index_with { "00:00-23:59" } # same shape as the seeded Taj Zayka
    @restaurant = Restaurant.create!(name: "Baseline Pizzeria", phone_number: "+15550001111", business_hours: all_day)
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

  def rec(**row) = BaselineObservations.record(**row)

  # --- Confirmation / order lifecycle ---

  test "R01 submit_order is accepted without any prior get_cart read-back" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    result = tool(c.external_call_id, "submit_order", { fulfillment_type: "pickup" })

    assert c.reload.order.confirmed?
    rec(id: "R01", scenario: "Submit without read-back", layer: "vapi",
        current: "Accepted; order confirmed. No get_cart call was required. Result: #{result}",
        safe: "Reject unless the cart was read back (via server) after the last change")
  end

  test "R02 submitting twice re-confirms, moves placed_at, and enqueues a second SMS" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    tool(c.external_call_id, "submit_order", { fulfillment_type: "pickup" })
    first_placed = c.reload.order.placed_at
    travel 1.minute do
      tool(c.external_call_id, "submit_order", { fulfillment_type: "delivery", delivery_address: "1 Main St" })
    end
    order = c.reload.order

    assert_equal 2, enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }
    assert_not_equal first_placed, order.placed_at
    assert order.delivery?
    rec(id: "R02", scenario: "Submit twice", layer: "vapi",
        current: "Second submit accepted: 2 OrderConfirmationSmsJob enqueued, placed_at overwritten, fulfillment switched pickup->delivery on an already-confirmed order",
        safe: "Idempotent: second submit returns the existing confirmation; no second SMS; no field changes")
  end

  test "R03 items can be added and removed after the order is confirmed (and after kitchen status moves on)" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    tool(c.external_call_id, "submit_order", { fulfillment_type: "pickup" })
    order = c.reload.order
    order.update!(status: :preparing) # admin/kitchen advanced it
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @knots.id })
    item_id = order.order_items.find_by(menu_item: @margherita).id
    tool(c.external_call_id, "remove_cart_item", { order_item_id: item_id })
    order.reload

    assert order.preparing?
    assert_equal [ "Garlic Knots" ], order.order_items.map { |i| i.menu_item.name }
    assert_equal 550, order.total_cents
    rec(id: "R03", scenario: "Modify order after submission", layer: "vapi",
        current: "Order in 'preparing' was mutated by voice tools: Margherita removed, Garlic Knots added, total 1400->550 cents; no error",
        safe: "Reject cart mutations once the order is submitted")
  end

  # --- Input validation ---

  test "R04 a modifier belonging to another item is silently dropped" do
    c = start_call
    result = JSON.parse(tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, modifier_ids: [ @bacon.id ] }))
    item = c.reload.order.order_items.last

    assert_equal [], item.selected_modifiers
    assert_equal 1400, item.unit_price_cents
    rec(id: "R04", scenario: "Invalid modifier (belongs to another item)", layer: "vapi",
        current: "Item added WITHOUT the modifier; no error returned (result: #{result.to_json})",
        safe: "Reject with an actionable error naming the valid modifiers")
  end

  test "R05 a nonexistent modifier id is silently dropped" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, modifier_ids: [ 999_999 ] })

    assert_equal [], c.reload.order.order_items.last.selected_modifiers
    rec(id: "R05", scenario: "Invalid modifier (nonexistent id)", layer: "vapi",
        current: "Item added without modifier; no error",
        safe: "Reject with an actionable error")
  end

  def create_other_restaurant_item
    other = Restaurant.create!(name: "Other Place", phone_number: "+15550002222")
    other.menu_categories.create!(name: "X", position: 1).menu_items.create!(restaurant: other, name: "Foreign Item", price_cents: 100)
  end

  test "R06 unknown, unavailable and foreign menu items are rejected, but with raw exception text" do
    c = start_call
    @foreign_item = create_other_restaurant_item # created after call start; see R23 for why
    unknown = tool(c.external_call_id, "add_to_cart", { menu_item_id: 999_999 })
    sold_out = tool(c.external_call_id, "add_to_cart", { menu_item_id: @sold_out.id })
    foreign = tool(c.external_call_id, "add_to_cart", { menu_item_id: @foreign_item.id })

    [ unknown, sold_out, foreign ].each { |r| assert_match(/\ASorry, something went wrong handling that - Couldn't find MenuItem/, r) }
    assert_nil c.reload.order
    rec(id: "R06", scenario: "Invalid / unavailable / other-restaurant menu item", layer: "vapi",
        current: "Not inserted (safe). Error returned to the LLM is raw ActiveRecord text, e.g. #{unknown.inspect}",
        safe: "Not inserted, with a structured, speakable error code (e.g. item_unavailable)")
  end

  test "R07 quantity has no upper bound; zero/negative fail with raw validation text" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, quantity: 500 })
    zero = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, quantity: 0 })
    negative = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, quantity: -3 })
    words = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, quantity: "two" })
    order = c.reload.order

    assert_equal [ 500 ], order.order_items.map(&:quantity)
    assert_equal 700_000, order.total_cents
    [ zero, negative, words ].each { |r| assert_match(/\ASorry, something went wrong handling that - Validation failed: Quantity/, r) }
    rec(id: "R07", scenario: "Excessive / invalid quantity", layer: "vapi",
        current: "quantity 500 accepted (order total $7,000.00). 0, -3 and \"two\" rejected with raw text: #{zero.inspect}",
        safe: "Upper bound; large orders routed to a human (the prompt's 'large order -> transfer' rule enforced server-side)")
  end

  test "R08 orders are accepted while the restaurant is closed" do
    @restaurant.update!(business_hours: %w[sun mon tue wed thu fri sat].index_with { "closed" })
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    tool(c.external_call_id, "submit_order", { fulfillment_type: "pickup" })

    assert_not @restaurant.open_now?
    assert c.reload.order.confirmed?
    rec(id: "R08", scenario: "Order while restaurant closed", layer: "vapi",
        current: "open_now? is false, submit_order still confirms. The Vapi path never exposes or checks hours",
        safe: "Reject submission when closed, with a speakable reason")
  end

  test "R09 the seeded 24/7 hours (00:00-23:59) report closed during the last minute of each day" do
    tz = ActiveSupport::TimeZone[@restaurant.timezone]
    assert @restaurant.open_now?(at: tz.local(2026, 9, 30, 23, 59, 0))
    assert_not @restaurant.open_now?(at: tz.local(2026, 9, 30, 23, 59, 30))
    rec(id: "R09", scenario: "24/7 hours edge (seed data)", layer: "model",
        current: "open_now? false from 23:59:01 to 23:59:59 local time with the seeded '00:00-23:59' hours",
        safe: "A real 24-hour representation (or document the one-minute gap)")
  end

  # --- Malformed arguments / raw exceptions ---

  test "R10 malformed tool arguments reach business logic and return raw Ruby exception text" do
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
    no_address = tool(c.external_call_id, "submit_order", { fulfillment_type: "delivery" })

    assert_match(/key not found: "menu_item_id"/, missing)
    assert_match(/unexpected|expected/i, bad_json)
    assert_match(/undefined method 'order_items' for nil/, no_cart_update)
    assert_match(/'teleport' is not a valid fulfillment_type/, bad_enum)
    assert_match(/Delivery address can't be blank/, no_address)
    rec(id: "R10", scenario: "Malformed tool arguments / raw exception exposure", layer: "vapi",
        current: "All caught by one `rescue => e` and returned to the LLM verbatim: #{[ missing, bad_json, no_cart_update, bad_enum ].map(&:inspect).join(' | ')}",
        safe: "Validate arguments at the boundary; return structured error codes; never expose exception text")
  end

  test "R11 tool call for an unknown call, and an unknown tool name" do
    unknown_call = tool("no_such_call", "get_menu")
    c = start_call
    unknown_tool = tool(c.external_call_id, "delete_everything")

    assert_equal "No active call found for this request.", unknown_call
    assert_equal "Unknown tool: delete_everything", unknown_tool
    rec(id: "R11", scenario: "Unknown call id / unknown tool", layer: "vapi",
        current: "Handled with fixed strings (#{unknown_call.inspect}, #{unknown_tool.inspect}); HTTP 200",
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

  test "R14 the same tool-call id delivered twice adds the item twice" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id }, tool_call_id: "call_same")
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id }, tool_call_id: "call_same")

    assert_equal 2, c.reload.order.order_items.count
    assert_equal 2800, c.order.total_cents
    rec(id: "R14", scenario: "Duplicate tool call (same toolCallId redelivered)", layer: "vapi",
        current: "Two order items, total doubled (2800 cents). toolCallId is not recorded anywhere",
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

  test "R16 add_to_cart is not atomic across its writes" do
    c = start_call
    original = OrderItem.instance_method(:save!)
    OrderItem.define_method(:save!) { |*| raise ActiveRecord::StatementInvalid, "simulated failure" }
    begin
      result = tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    ensure
      OrderItem.define_method(:save!, original)
    end
    c.reload

    assert c.order, "an empty order was left linked to the call"
    assert_equal 0, c.order.order_items.count
    rec(id: "R16", scenario: "Partial failure inside add_to_cart", layer: "vapi",
        current: "Order created and linked to the call, item insert failed -> empty pending order left behind; LLM got #{result.inspect}",
        safe: "Single transaction; nothing persisted on failure")
  end

  test "R17 a call that ends with items but no submit leaves a pending order forever" do
    c = start_call
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id })
    vapi(type: "end-of-call-report", call: { id: c.external_call_id }, artifact: { transcript: "AI: bye" })

    assert c.reload.abandoned?
    assert c.order.pending?
    rec(id: "R17", scenario: "Abandoned call with unsubmitted cart", layer: "vapi",
        current: "CallLog abandoned; its order stays 'pending' with items and a total, indistinguishable in the orders list from a live cart",
        safe: "Mark the cart abandoned/cancelled at end of call")
  end

  test "R23 a call with no dialed number is silently dropped once a second restaurant exists" do
    create_other_restaurant_item
    c = start_call("orphan_call")
    menu = tool("orphan_call", "get_menu")

    assert_nil c
    assert_response :success
    assert_equal "No active call found for this request.", menu
    rec(id: "R23", scenario: "Restaurant resolution for web calls (no dialed number)", layer: "vapi",
        current: "Works only while exactly one Restaurant exists (Restaurant.count == 1 fallback). With two, no CallLog is created (HTTP 200, warning log only) and every tool returns 'No active call found'",
        safe: "Explicit restaurant resolution (e.g. assistant metadata) and a loud failure; documented single-tenant assumption")
  end

  # --- SMS ---

  test "R18 SMS: no-op without Twilio config; with config it texts a synthetic caller id and is not itemized" do
    c = start_call("sms_call")
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @margherita.id, modifier_ids: [ @extra_cheese.id ] })
    tool(c.external_call_id, "add_to_cart", { menu_item_id: @knots.id })
    tool(c.external_call_id, "submit_order", { fulfillment_type: "pickup" })
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

# Step 0 (Phase 1): runnable copy of the frozen Phase 0 file
# test/fixtures/files/baseline/live_call_replay_test.rb.frozen. This copy is part of the live suite and is
# expected to evolve with Phase 1; the frozen original is never edited (see baseline:verify).
# Only change vs. the original: DIR points at the frozen fixtures instead of this file's directory.
# Phase 0 baseline: replay the two real Vapi calls through the unchanged webhook controller.
#
# Every logged event for each call is POSTed in its original order. The menu is recreated with the
# original development-database ids (from db_snapshot.json) so the LLM's real arguments
# (menu_item_id 5, modifier_ids [6]) resolve exactly as they did live. Tool results produced by the
# replay are compared with the results Vapi actually received (from the final conversation-update).
#
# Known fidelity gap: the dev log excluded `artifact` from end-of-call-report, so the replayed report
# carries the transcript captured in the database (which is what `artifact.transcript` stored) and no
# recording URL.
#
#   bin/rails test <path-to-this-file>
require "test_helper"
require "json"

class BaselineLiveCallReplayTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  DIR = Rails.root.join("test/fixtures/files/baseline").to_s

  setup do
    ENV["VAPI_SERVER_SECRET"] = "test-vapi-secret"
    snap = JSON.parse(File.read(File.join(DIR, "db_snapshot.json")))
    @snapshot = snap
    r = snap["restaurant"]
    @restaurant = Restaurant.create!(id: r["id"], name: r["name"], phone_number: "+15550001111",
                                     timezone: r["timezone"], business_hours: ALWAYS_OPEN_HOURS) # snapshot hours were 00:00-23:59; see Step 4 log
    menu = snap["menu_reference"]
    menu["categories"].each do |c|
      @restaurant.menu_categories.create!(id: c["id"], name: c["name"], position: c["position"])
    end
    menu["items"].each do |i|
      MenuItem.create!(i.slice("id", "menu_category_id", "name", "description", "price_cents", "available", "position").merge(restaurant: @restaurant))
    end
    menu["modifiers"].each { |m| MenuItemModifier.create!(m.slice("id", "menu_item_id", "name", "price_cents", "position")) }
    menu["upsells"].each { |u| MenuItemUpsell.create!(u.slice("id", "menu_item_id", "upsell_item_id")) }
  end

  teardown { ENV.delete("VAPI_SERVER_SECRET") }

  # Phase 1 (Steps 0-2 follow-up): recording failures are swallowed by design, so replays must prove none happened.
  def replay(call_dir, db_call_id)
    log = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    begin
      replay_events(call_dir, db_call_id)
    ensure
      Rails.logger = original_logger
    end.tap { assert_no_match(/could not record tool invocation/, log.string) }
  end

  def replay_events(call_dir, db_call_id)
    events = JSON.parse(File.read(File.join(DIR, call_dir, "events.json")))
    transcript = @snapshot["call_logs"].find { |c| c["id"] == db_call_id }["transcript_verbatim"]
    tool_results = {}
    statuses = []
    events.each do |e|
      message = e["payload"].deep_dup
      message["artifact"] = { "transcript" => transcript } if e["type"] == "end-of-call-report"
      post api_vapi_webhooks_path, params: { message: message }, headers: { "X-Vapi-Secret" => "test-vapi-secret" }, as: :json
      statuses << response.status
      if e["type"] == "tool-calls"
        JSON.parse(response.body)["results"].each { |res| tool_results[res["toolCallId"]] = res["result"] }
      end
    end
    [ events, tool_results, statuses ]
  end

  def recorded_results(call_dir)
    timeline = JSON.parse(File.read(File.join(DIR, call_dir, "timeline.json")))
    timeline.select { |row| row["role"] == "tool_call_result" }.to_h { |row| [ row["tool_call_id"], row["result"] ] }
  end

  # Order-item ids differ between the dev DB and the test DB; everything else must match.
  def normalize(result)
    JSON.parse(result).then { |j| JSON.generate(strip_ids(j)) }
  rescue JSON::ParserError
    result
  end

  def strip_ids(o)
    case o
    when Hash then o.reject { |k, _| k == "id" && o.key?("menu_item") }.transform_values { |v| strip_ids(v) }
    when Array then o.map { |v| strip_ids(v) }
    else o
    end
  end

  test "call #6 (assistant with zero tools) replays to an abandoned call with no order and no tool calls" do
    events, tool_results, statuses = replay("call6", 6)
    call = CallLog.find_by!(external_call_id: "019fd4eb-3d46-788a-9c27-da2e2d2c1f10")

    assert_equal 25, events.size
    assert statuses.all?(200)
    assert_empty tool_results
    assert call.abandoned?
    assert_nil call.order
    assert call.phone_number.start_with?("unknown-"), "web call: no caller id"
    assert_equal @snapshot["call_logs"].find { |c| c["id"] == 6 }["transcript_verbatim"], call.transcript
  end

  # --- Call #7, Layer 2 (docs/phase1/PLAN.md section 8) ---
  #
  # The recorded get_cart/submit_order contract changed in Step 5 (get_cart returns cart_version + readback_text,
  # submit_order requires cart_version), so the verbatim "identical results" assertion became:
  #   (a) verbatim replay: every recorded tool result is still *covered* by the new result (superset, same
  #       values), and submit_order is refused because the recorded call never sent cart_version;
  #   (b) adapted replay: the same events with cart_version injected from the preceding get_cart -> the original
  #       confirmed $16 order;
  #   (c) dangerous variants: no get_cart -> readback_required; an add after the read-back -> cart_changed_since_readback.
  # The frozen original (identical-results version) still passes against the tag via baseline:verify.

  CALL7_ID = "019fd4fa-7f12-7227-ba8a-3f777c3af6d1".freeze

  def tool_names(events)
    events.select { |e| e["type"] == "tool-calls" }.flat_map { |e| e["payload"]["toolCallList"].map { |t| t["function"]["name"] } }
  end

  # recorded must appear in actual with the same values (actual may add keys).
  def covers?(recorded, actual)
    case recorded
    when Hash then recorded.all? { |k, v| actual.is_a?(Hash) && actual.key?(k) && covers?(v, actual[k]) }
    when Array then actual.is_a?(Array) && recorded.size == actual.size && recorded.zip(actual).all? { |r, a| covers?(r, a) }
    else recorded == actual
    end
  end

  def parsed(result) = JSON.parse(result)

  # Call #7's conversation history as Vapi's webhooks would have carried it (`artifact.messages`, read by the
  # confirmation gate). The Phase 0 log dropped `artifact`, so it is reconstructed from the call's final
  # conversation-update (the same Vapi message objects), cut at each webhook's own timestamp.
  def call7_history_at(snapshot_events, timestamp)
    messages = snapshot_events.reverse.find { |e| e["type"] == "conversation-update" && e["payload"]["messages"] }["payload"]["messages"]
    { "messages" => messages.select { |m| m["time"].to_i <= timestamp.to_i } }
  end

  # Replays call #7 with a transformation applied to the event list; returns results keyed by toolCallId.
  def replay_call7(&transform)
    snapshot_events = JSON.parse(File.read(File.join(DIR, "call7", "events.json")))
    events = transform ? transform.call(snapshot_events.deep_dup) : snapshot_events
    transcript = @snapshot["call_logs"].find { |c| c["id"] == 7 }["transcript_verbatim"]
    results = {}
    events.each do |e|
      message = e["payload"].deep_dup
      message["artifact"] = { "transcript" => transcript } if e["type"] == "end-of-call-report"
      message["artifact"] = call7_history_at(snapshot_events, message["timestamp"]) if e["type"] == "tool-calls" && message["timestamp"]
      if e["type"] == "tool-calls" && message["toolCallList"].any? { |t| t["function"]["name"] == "submit_order" } && block_given? && @inject_version
        version = @inject_version == true ? results.values.map { |r| parsed(r) }.select { |j| j.is_a?(Hash) && j["readback_text"] }.last&.fetch("cart_version") : @inject_version
        message["toolCallList"].each { |t| t["function"]["arguments"]["cart_version"] = version if t["function"]["name"] == "submit_order" }
      end
      post api_vapi_webhooks_path, params: { message: message }, headers: { "X-Vapi-Secret" => "test-vapi-secret" }, as: :json
      assert_response :success
      next unless e["type"] == "tool-calls"

      JSON.parse(response.body)["results"].each { |res| results[res["toolCallId"]] = res["result"] }
    end
    [ events, results ]
  end

  test "call #7 verbatim: recorded results are still covered, submit_order is refused without cart_version" do
    events, results = replay_call7
    call = CallLog.find_by!(external_call_id: CALL7_ID)
    recorded = recorded_results("call7")
    names = tool_names(events)

    assert_equal %w[get_menu add_to_cart get_cart submit_order], names
    assert_equal recorded.keys.sort, results.keys.sort
    timeline_ids = events.select { |e| e["type"] == "tool-calls" }.map { |e| e["payload"]["toolCallList"].first["id"] }
    # get_menu itself changed shape in Step 6 (compact overview); see the dedicated menu test below.
    timeline_ids[1..2].each do |id|
      assert covers?(JSON.parse(normalize(recorded[id])), JSON.parse(normalize(results[id]))), "recorded result no longer covered for #{id}: #{results[id]}"
    end

    submit = parsed(results[timeline_ids[3]])
    assert_equal false, submit["ok"]
    assert_equal "invalid_arguments", submit.dig("error", "code")
    assert_match(/cart_version is required/, submit.dig("error", "message"))

    order = call.order
    assert order.abandoned?, "unsubmitted cart is abandoned at call end (R17)"
    assert call.abandoned?
    assert_equal [ [ "Margherita Pizza", 1, [ "Extra cheese" ] ] ],
                 order.order_items.map { |i| [ i.menu_item.name, i.quantity, i.selected_modifiers.map { |m| m["name"] } ] }
    assert_equal 0, enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }
  end

  # Step 6: the recorded get_menu (full menu, 4,554 bytes, 51 queries) is now split into a compact get_menu plus
  # get_menu_item. Between them they must still carry everything the real call's get_menu carried.
  test "call #7 menu: get_menu + get_menu_item cover the recorded full get_menu" do
    recorded_id = recorded_results("call7").keys.first
    full_menu = JSON.parse(recorded_results("call7").fetch(recorded_id))
    catalog = MenuCatalog.new(@restaurant)
    overview = catalog.overview

    assert_equal full_menu.map { |c| c["category"] }, overview.map { |c| c[:category] }
    full_menu.zip(overview).each do |recorded_category, category|
      assert_equal recorded_category["items"].map { |i| i["id"] }, category[:items].map { |i| i[:id] }
      recorded_category["items"].zip(category[:items]).each do |recorded_item, item|
        assert_equal [ recorded_item["name"], recorded_item["price"], recorded_item["modifiers"].any? ],
                     [ item[:name], item[:price], item[:customizable] ], recorded_item["name"]
        detail = JSON.parse(catalog.item(recorded_item["id"]).to_json)
        assert_equal recorded_item, detail, "get_menu_item must carry the recorded detail for #{recorded_item['name']}"
      end
    end
  end

  test "call #7 adapted (cart_version injected from get_cart) replays to the same confirmed $16 order" do
    @inject_version = true
    events = nil
    # Call #7 was a browser call (no caller number): the order is confirmed and the SMS is explicitly skipped.
    assert_no_enqueued_jobs only: OrderConfirmationSmsJob do
      events, results = replay_call7 { |e| e }
      @results = results
    end
    call = CallLog.find_by!(external_call_id: CALL7_ID)
    order = call.order

    assert_equal 124, events.size
    assert_equal %w[get_menu add_to_cart get_cart submit_order], tool_names(events)
    recorded = recorded_results("call7")
    assert_equal recorded.keys.sort, @results.keys.sort
    ids = events.select { |e| e["type"] == "tool-calls" }.map { |e| e["payload"]["toolCallList"].first["id"] }
    ids[1..2].each { |id| assert covers?(JSON.parse(normalize(recorded[id])), JSON.parse(normalize(@results[id]))), id }
    assert_equal true, parsed(@results[ids[3]])["ok"]
    assert_not parsed(@results[ids[3]]).key?("confirmation_sms"), "a browser call: the model is told nothing about SMS"

    assert call.completed?
    assert order.confirmed?
    assert order.pickup?
    assert_equal 1600, order.total_cents
    assert_equal 1, order.cart_version
    assert_equal order.cart_version, order.read_back_version
    assert_equal [ [ "Margherita Pizza", 1, [ "Extra cheese" ] ] ],
                 order.order_items.map { |i| [ i.menu_item.name, i.quantity, i.selected_modifiers.map { |m| m["name"] } ] }
    assert_not order.order_items.joins(:menu_item).exists?(menu_items: { name: "Garlic Knots" }),
               "the agent said it would add garlic knots; no add_to_cart for them was ever issued"
    assert_equal @snapshot["call_logs"].find { |c| c["id"] == 7 }["transcript_verbatim"], call.transcript

    # Every real tool call left a ToolInvocation with the real Vapi timestamp (epoch ms) - none silently dropped.
    tool_events = events.select { |e| e["type"] == "tool-calls" }
    invocations = call.tool_invocations.order(:started_at, :id)
    assert_equal tool_events.size, invocations.count
    tool_events.zip(invocations).each do |event, invocation|
      payload = event["payload"]
      assert_equal payload["toolCallList"].first["id"], invocation.tool_call_id
      assert_equal payload["toolCallList"].first["function"]["name"], invocation.tool_name
      assert_equal Time.zone.at(payload["timestamp"] / 1000, payload["timestamp"] % 1000, :millisecond), invocation.vapi_requested_at
      assert_predicate invocation, :ok?
    end
  end

  test "call #7 dangerous variant: no get_cart before submit_order -> readback_required" do
    @inject_version = 1 # a model that skipped get_cart and guessed the version
    events, results = replay_call7 do |all|
      all.reject { |e| e["type"] == "tool-calls" && e["payload"]["toolCallList"].any? { |t| t["function"]["name"] == "get_cart" } }
    end
    submit_id = events.select { |e| e["type"] == "tool-calls" }.last["payload"]["toolCallList"].first["id"]

    assert_equal "readback_required", parsed(results[submit_id]).dig("error", "code")
    order = CallLog.find_by!(external_call_id: CALL7_ID).order
    assert_not order.confirmed?
    assert_equal 0, enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }
  end

  test "call #7 dangerous variant: an item added after the read-back makes the submit stale" do
    @inject_version = true
    events, results = replay_call7 do |all|
      extra = all.find { |e| e["type"] == "tool-calls" && e["payload"]["toolCallList"].any? { |t| t["function"]["name"] == "add_to_cart" } }.deep_dup
      extra["payload"]["toolCallList"].each { |t| t["id"] = "injected_add" }
      get_cart_index = all.index { |e| e["type"] == "tool-calls" && e["payload"]["toolCallList"].any? { |t| t["function"]["name"] == "get_cart" } }
      all.insert(get_cart_index + 1, extra)
    end
    submit_id = events.select { |e| e["type"] == "tool-calls" }.last["payload"]["toolCallList"].first["id"]
    refused = parsed(results[submit_id])

    assert_equal false, refused["ok"]
    assert_equal "cart_changed_since_readback", refused.dig("error", "code")
    assert_equal 2, refused.dig("error", "cart_version")
    order = CallLog.find_by!(external_call_id: CALL7_ID).order
    assert_not order.confirmed?
    assert_equal 2, order.order_items.count
    assert_equal 0, enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }
  end
end

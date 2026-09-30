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
                                     timezone: r["timezone"], business_hours: r["business_hours"])
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

  def replay(call_dir, db_call_id)
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

  test "call #7 (garlic knots) replays to the same confirmed $16 order with identical tool results" do
    events = nil
    assert_enqueued_jobs 1, only: OrderConfirmationSmsJob do
      events, @tool_results, @statuses = replay("call7", 7)
    end
    call = CallLog.find_by!(external_call_id: "019fd4fa-7f12-7227-ba8a-3f777c3af6d1")
    order = call.order

    assert_equal 124, events.size
    assert @statuses.all?(200)
    assert_equal %w[get_menu add_to_cart get_cart submit_order],
                 events.select { |e| e["type"] == "tool-calls" }.flat_map { |e| e["payload"]["toolCallList"].map { |t| t["function"]["name"] } }

    recorded = recorded_results("call7")
    assert_equal recorded.keys.sort, @tool_results.keys.sort
    recorded.each { |id, result| assert_equal normalize(result), normalize(@tool_results[id]), "tool result mismatch for #{id}" }

    assert call.completed?
    assert order.confirmed?
    assert order.pickup?
    assert_equal 1600, order.total_cents
    assert_equal [ [ "Margherita Pizza", 1, [ "Extra cheese" ] ] ],
                 order.order_items.map { |i| [ i.menu_item.name, i.quantity, i.selected_modifiers.map { |m| m["name"] } ] }
    assert_not order.order_items.joins(:menu_item).exists?(menu_items: { name: "Garlic Knots" }),
               "the agent said it would add garlic knots; no add_to_cart for them was ever issued"
    assert_equal @snapshot["call_logs"].find { |c| c["id"] == 7 }["transcript_verbatim"], call.transcript
  end
end

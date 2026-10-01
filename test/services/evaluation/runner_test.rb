require "test_helper"

class Evaluation::RunnerTest < ActiveSupport::TestCase
  RESULTS = Evaluation::Runner.run_all.index_by { |r| r["id"] }.freeze

  def result(id) = RESULTS.fetch(id)
  def summary(id) = result(id)["summary"]

  # id => [claims, claims not in the server order, flagged by the window heuristic, tool calls, mutations, refused, duplicates, final status, cart version]
  EXPECTED = {
    "call7_verbatim" => [ 1, 1, 1, 4, 1, 1, 0, "abandoned", 1 ],
    "call7_adapted" => [ 1, 1, 1, 4, 1, 0, 0, "confirmed", 1 ],
    "control_no_claim" => [ 0, 0, 0, 4, 1, 0, 0, "confirmed", 1 ],
    "claim_then_accepted_add" => [ 1, 0, 0, 5, 2, 0, 0, "confirmed", 2 ],
    "claim_then_rejected_add" => [ 1, 1, 1, 3, 1, 1, 0, "abandoned", 1 ],
    "claim_tool_arrives_late" => [ 1, 0, 1, 3, 2, 0, 0, "abandoned", 2 ],
    "two_items_claimed_one_added" => [ 1, 1, 0, 3, 2, 0, 0, "abandoned", 2 ],
    "remove_claimed_without_tool" => [ 1, 1, 1, 2, 1, 0, 0, "abandoned", 1 ],
    "change_claimed_and_done" => [ 1, 0, 0, 3, 2, 0, 0, "abandoned", 2 ],
    "submit_without_read_back" => [ 1, 0, 0, 4, 2, 1, 0, "abandoned", 2 ],
    "stale_submit_after_change" => [ 0, 0, 0, 6, 2, 2, 0, "abandoned", 2 ],
    "late_duplicate_get_cart" => [ 0, 0, 0, 5, 2, 1, 1, "abandoned", 2 ],
    "duplicate_claimed_add" => [ 1, 0, 0, 3, 2, 0, 1, "abandoned", 2 ],
    "claim_after_confirmation" => [ 1, 1, 1, 5, 1, 1, 0, "confirmed", 1 ],
    "premature_submit_then_answered" => [ 0, 0, 0, 5, 1, 1, 0, "confirmed", 1 ]
  }.freeze

  test "every scenario runs and matches its expected outcome" do
    assert_equal EXPECTED.keys.sort, RESULTS.keys.sort
    EXPECTED.each do |id, (claims, unreflected, flagged, received, mutated, refused, dups, status, version)|
      s = summary(id)
      assert_equal [ claims, unreflected, flagged, received, mutated, refused, dups, status, version ],
                   [ s["assistant_claims"], s["claims_not_reflected_in_server_order"], s["claims_flagged_by_console_window"], s["tool_calls_received"],
                     s["tool_calls_that_mutated_the_cart"], s["tool_calls_refused"], s["duplicate_deliveries_absorbed"], s["final_order_status"], s["final_cart_version"] ], id
    end
  end

  test "the two safety invariants hold in every scenario, however the scripted assistant behaves" do
    RESULTS.each_value do |r|
      assert_equal true, r["invariants"]["every_order_line_came_from_an_accepted_add_to_cart"], r["id"]
      assert_not_equal false, r["invariants"]["confirmed_only_at_the_read_back_version"], r["id"]
    end
  end

  test "the garlic knots failure, end to end: the claim, the tools the server saw, the mutation, the authoritative order" do
    r = result("call7_adapted")
    claim = r["claims"].sole

    # 1. what the assistant claimed: verbatim from the recording
    recorded = JSON.parse(Rails.root.join("test/fixtures/files/baseline/call7/timeline.json").read).find { |row| row["role"] == "bot" && row["message"].include?("I'll add garlic knots") }
    assert_equal [ recorded["message"], recorded["t"], "add" ], [ claim["text"], claim["t"], claim["kind"] ]
    assert_includes claim["items_mentioned"], "Garlic Knots"

    # 2. and 3. what the server received and what actually changed the cart
    assert_equal %w[get_menu add_to_cart get_cart submit_order], r["tool_calls"].map { |t| t["tool"] }
    assert_equal [ "add_to_cart" ], r["tool_calls"].select { |t| t["mutated_cart"] }.map { |t| t["tool"] }
    assert_empty r["tool_calls"].select { |t| t["tool"] == "add_to_cart" && t["status"] != "ok" }

    # 4. the authoritative order: $16, Margherita only. The claim is reported, not honoured.
    assert_equal [ [ 1, "Margherita Pizza", [ "Extra cheese" ] ] ], r["final_order"]["lines"].map { |l| [ l["quantity"], l["item"], l["modifiers"] ] }
    assert_equal [ "confirmed", 16.0, 1, 1 ], r["final_order"].values_at("status", "total", "cart_version", "read_back_version")
    assert_equal [ "Garlic Knots" ], claim["missing_from_server_order"]
    assert_equal false, claim["state_backed"]
    assert_equal false, claim["window_backed"]
  end

  test "a tool call the server refuses is received but is not a mutation" do
    r = result("claim_then_rejected_add")
    refused = r["tool_calls"].find { |t| t["tool"] == "add_to_cart" && t["status"] != "ok" }
    assert_equal [ "rejected", "invalid_modifier", false, 1, 1 ], [ refused["status"], refused["error_code"], refused["mutated_cart"], refused["cart_version_before"], refused["cart_version_after"] ]
    assert_equal [ "Garlic Knots" ], r["claims"].sole["missing_from_server_order"]
  end

  test "the console heuristic's documented false positive and false negative" do
    late = result("claim_tool_arrives_late")["claims"].sole
    assert_equal [ false, true ], [ late["window_backed"], late["state_backed"] ], "flagged although the knots did arrive (12.5 s later)"
    two = result("two_items_claimed_one_added")["claims"].sole
    assert_equal [ true, false, [ "French Fries" ] ], [ two["window_backed"], two["state_backed"], two["missing_from_server_order"] ], "backed in time, yet the fries are missing"
  end

  test "the server stops a model that skips or replays the read-back" do
    skipped = result("submit_without_read_back")
    assert_equal "readback_required", skipped["tool_calls"].find { |t| t["tool"] == "submit_order" }["error_code"]
    assert_not_equal "confirmed", skipped["final_order"]["status"]

    stale = result("stale_submit_after_change")
    assert_equal %w[cart_changed_since_readback cart_changed_since_readback], stale["tool_calls"].select { |t| t["tool"] == "submit_order" }.map { |t| t["error_code"] }

    replayed = result("late_duplicate_get_cart")
    assert_equal 1, replayed["final_order"]["read_back_version"], "the duplicate get_cart did not refresh the read-back"
    assert_equal 2, replayed["final_order"]["cart_version"]
    assert_equal "cart_changed_since_readback", replayed["tool_calls"].find { |t| t["tool"] == "submit_order" }["error_code"]
  end

  test "the live premature-submit pattern: refused until the caller answers, then accepted" do
    r = result("premature_submit_then_answered")
    submits = r["tool_calls"].select { |t| t["tool"] == "submit_order" }
    assert_equal [ [ "rejected", "customer_confirmation_required" ], [ "ok", nil ] ], submits.map { |t| t.values_at("status", "error_code") }
    assert_equal [ "confirmed", 1, 1 ], r["final_order"].values_at("status", "cart_version", "read_back_version")
  end

  test "a confirmed order is locked against a later claimed add" do
    r = result("claim_after_confirmation")
    assert_equal "order_already_submitted", r["tool_calls"].last["error_code"]
    assert_equal [ "confirmed", 1 ], r["final_order"].values_at("status", "cart_version")
  end

  test "the control conversation produces no claims: the heuristic does not cry wolf" do
    assert_equal 0, summary("control_no_claim")["assistant_claims"]
  end

  test "a run leaves the database exactly as it found it" do
    before = [ Restaurant.count, CallLog.count, Order.count, ToolInvocation.count, MenuItem.count ]
    Evaluation::Runner.run(Evaluation::Scenarios.call7_adapted)
    assert_equal before, [ Restaurant.count, CallLog.count, Order.count, ToolInvocation.count, MenuItem.count ]
  end

  test "the recorded prefix is verbatim: every recorded line in a scenario appears in the fixture unchanged" do
    recorded = JSON.parse(Rails.root.join("test/fixtures/files/baseline/call7/timeline.json").read).filter_map { |row| [ row["t"], row["message"] ] if row["message"] }
    Evaluation::Scenarios.call7_verbatim.events.select { |e| e.kind == :say }.each { |event| assert_includes recorded, [ event.t, event.text ] }
  end
end

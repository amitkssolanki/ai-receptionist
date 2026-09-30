require "test_helper"

class Evaluation::EvidenceTest < ActiveSupport::TestCase
  DIR = Evaluation::Evidence::DIR

  def committed(name) = JSON.parse(DIR.join(name).read)

  # Everything except wall-clock timings must match a fresh run: the committed evidence cannot silently go stale.
  def stable(result) = result.merge("tool_calls" => result["tool_calls"].map { |t| t.except("server_ms") })

  test "the committed probe evidence equals a fresh run of the same scenarios" do
    fresh = Evaluation::Runner.run_all.map { |r| stable(r) }
    assert_equal fresh, committed("garlic_knots_probe.json")["scenarios"].map { |r| stable(r) },
                 "docs/phase1/evidence is stale: run RAILS_ENV=test bin/rails evidence:generate and commit the result"
  end

  test "the totals add up from the scenarios" do
    probe = committed("garlic_knots_probe.json")
    sums = probe["scenarios"].map { |s| s["summary"] }
    assert_equal sums.sum { |s| s["assistant_claims"] }, probe["totals"]["assistant_claims"]
    assert_equal sums.sum { |s| s["claims_not_reflected_in_server_order"] }, probe["totals"]["claims_not_reflected_in_server_order"]
    assert_equal sums.sum { |s| s["tool_calls_received"] }, probe["totals"]["tool_calls_received_by_server"]
    assert_equal probe["scenarios"].size, probe["totals"]["invariant_every_order_line_came_from_an_accepted_add_to_cart_held_in"]
  end

  test "live evidence is marked pending, never reported as a result" do
    probe = committed("garlic_knots_probe.json")
    assert_match(/\APENDING/, probe["live_model_sample"])
    manifest = committed("manifest.json")
    assert_equal "PENDING", manifest["live_evidence"]["status"]
    assert_operator manifest["live_evidence"]["items"].size, :>=, 3
  end

  test "the duplicate-delivery demos show one execution, stored results, and no refreshed read-back" do
    demos = committed("idempotency_and_versions.json")["duplicate_delivery_demos"]
    assert_equal [ true, 1, 1, 2 ], demos["duplicate_add_to_cart"].values_at("identical_stored_result", "order_lines", "cart_version", "replay_count")
    cart = demos["late_duplicate_get_cart"]
    assert_equal [ 1, 1, true, "cart_changed_since_readback" ], cart.values_at("duplicate_get_cart_returned_version", "read_back_version_after_duplicate", "read_back_at_unchanged", "submit_with_current_version_refused_as")
    assert_equal [ true, "already_handled", "confirmed" ], demos["duplicate_submit_order"].then { |d| [ d["same_id_twice_identical"], d.dig("new_id_answer", "confirmation_sms"), d["order_status"] ] }
  end

  test "the latency file says what it does and does not measure, and covers every tool that ran" do
    latency = committed("latency.json")
    assert_match(/ToolInvocation.duration_ms/, latency["what_it_measures"])
    assert_match(/Vapi round-trip/, latency["not_measured"])
    assert_equal %w[add_to_cart get_cart get_menu submit_order update_cart_item_quantity], latency["after_phase1"].keys.sort
  end

  test "the manifest's hashes match the files on disk" do
    manifest = committed("manifest.json")
    manifest["files"].each { |name, digest| assert_equal digest, Digest::SHA256.file(DIR.join(name)).hexdigest, name }
  end

  test "no evidence file contains a secret, a phone number or a provider URL" do
    Dir[DIR.join("*.json")].each do |path|
      text = File.read(path)
      assert_no_match(/https?:\/\/(?!docs)|\+\d{10,}|Bearer|X-Vapi-Secret|sk_live|private[_ ]key/i, text.gsub("https://github.com", ""), path)
    end
  end
end

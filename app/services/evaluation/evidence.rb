require "digest"
require "open3"

module Evaluation
  # Builds the machine-readable evidence files under docs/phase1/evidence. Everything comes from running the real server
  # path on recorded/scripted scenarios (and, for the suite counts, from running the test suite); nothing is typed in.
  # The live parts of the plan (real Vapi calls, a live-model sample) are listed as PENDING, never as results.
  module Evidence
    DIR = Rails.root.join("docs/phase1/evidence")
    BASELINE_TIMINGS = Rails.root.join("test/fixtures/files/baseline/call7/tool_timings.json")

    module_function

    def generate
      results = Runner.run_all
      files = {
        "garlic_knots_probe.json" => probe(results),
        "latency.json" => latency(results),
        "idempotency_and_versions.json" => idempotency(results)
      }
      FileUtils.mkdir_p(DIR)
      files.each { |name, body| DIR.join(name).write(JSON.pretty_generate(body) + "\n") }
      DIR.join("manifest.json").write(JSON.pretty_generate(manifest(files.keys)) + "\n")
      files.keys + [ "manifest.json" ]
    end

    # --- the garlic-knots probe ---

    def probe(results)
      sums = results.map { |r| r["summary"] }
      {
        "claim" => "The model proposes. The server decides.",
        "what_was_run" => "#{results.size} scripted scenarios through Voice::ToolRunner -> OrderTaking -> ToolInvocation. Each prefix up to the claim is verbatim from real call #7; what follows is a deliberate variation. No model and no Vapi call is involved.",
        "live_model_sample" => "PENDING: plan Layer 3a (gpt-5-mini, N=20 per probe) needs Vapi/OpenAI access and has not been run. These results say what the SERVER does with an assistant that claims things; they say nothing about how often a live model does.",
        "caveat_timing" => "Recorded speech times in call #7 are Vapi speech offsets (about 4.5 s off the tool-call clock, see test/fixtures/files/baseline/README.md); claim-window results for the recorded scenarios are indicative.",
        "totals" => {
          "scenarios" => results.size,
          "assistant_claims" => sums.sum { |s| s["assistant_claims"] },
          "claims_not_reflected_in_server_order" => sums.sum { |s| s["claims_not_reflected_in_server_order"] },
          "claims_flagged_by_console_window_heuristic" => sums.sum { |s| s["claims_flagged_by_console_window"] },
          "claims_indeterminate" => sums.sum { |s| s["claims_indeterminate"] },
          "tool_calls_received_by_server" => sums.sum { |s| s["tool_calls_received"] },
          "tool_calls_that_mutated_the_cart" => sums.sum { |s| s["tool_calls_that_mutated_the_cart"] },
          "tool_calls_refused_by_server" => sums.sum { |s| s["tool_calls_refused"] },
          "duplicate_deliveries_absorbed" => sums.sum { |s| s["duplicate_deliveries_absorbed"] },
          "scenarios_ending_confirmed" => sums.count { |s| s["final_order_status"] == "confirmed" },
          "invariant_every_order_line_came_from_an_accepted_add_to_cart_held_in" => results.count { |r| r["invariants"]["every_order_line_came_from_an_accepted_add_to_cart"] },
          "invariant_confirmed_only_at_the_read_back_version_held_in" => results.count { |r| r["invariants"]["confirmed_only_at_the_read_back_version"] != false }
        },
        "reading_the_totals" => "A claim 'not reflected in the server order' is reported, never repaired: the server order contains only what accepted tool calls put there. 'Window heuristic' is the console's display-only rule (no cart change within -2s/+8s of the claim); it has a documented false positive (claim_tool_arrives_late) and false negative (two_items_claimed_one_added).",
        "scenarios" => results
      }
    end

    # --- latency ---

    def latency(results)
      calls = results.flat_map { |r| r["tool_calls"] }.select { |c| c["replay_count"].zero? }
      by_tool = calls.group_by { |c| c["tool"] }.transform_values do |rows|
        ms = rows.map { |c| c["server_ms"] }.sort
        { "runs" => ms.size, "median_ms" => ms[ms.size / 2], "max_ms" => ms.last, "min_ms" => ms.first }
      end
      baseline = JSON.parse(BASELINE_TIMINGS.read)["tools"].to_h { |t| [ t["tool"], { "server_total_ms" => t["server_total_ms"], "queries" => t["queries"], "response_bytes" => t["response_bytes"] } ] }
      {
        "what_it_measures" => "Server-side execution time of each tool call as recorded in ToolInvocation.duration_ms (argument parsing, business logic, audit row in one transaction), measured on the machine that generated this file, test database, single process.",
        "not_measured" => "Vapi round-trip latency, STT/LLM/TTS time, network, or the browser-observed latency. (One live call measured them: see docs/voice_agent/verification_log.md; they are not part of this generated file.)",
        "after_phase1" => by_tool.sort.to_h,
        "baseline_one_sample_for_reference" => baseline.merge("note" => "Phase 0, one real call; server_total_ms is the whole Rails request on the dev server, so it is not like-for-like with duration_ms. The menu payload went from 4,554 bytes / 53 queries to about 1.5 KB / 3 queries (see the Step 6 log entry)."),
        "measured_on" => { "ruby" => RUBY_VERSION, "rails" => Rails.version, "env" => Rails.env }
      }
    end

    # --- idempotency and cart versions ---

    def idempotency(results)
      { "cart_version_traces" => cart_version_traces(results), "duplicate_delivery_demos" => duplicate_demos }
    end

    def cart_version_traces(results)
      results.select { |r| %w[call7_adapted claim_then_accepted_add stale_submit_after_change late_duplicate_get_cart claim_after_confirmation].include?(r["id"]) }.map do |r|
        { "scenario" => r["id"], "trace" => r["tool_calls"].map { |c| c.slice("tool", "tool_call_id", "status", "error_code", "cart_version_before", "cart_version_after", "replay_count") },
          "final" => r["final_order"]&.slice("status", "cart_version", "read_back_version", "total") }
      end
    end

    # The same delivery repeated, straight against the runner: what comes back and what does not change.
    def duplicate_demos
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        world = World.new(call_id: "eval-dup")
        run = ->(id, name, args = {}, artifact = nil) { Voice::ToolRunner.call(call_log: CallLog.find(world.call_log.id), artifact: artifact, tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } }) }
        add_args = { "menu_item_id" => world.item_id("Garlic Knots"), "quantity" => 1 }

        first = run.("dup-add", "add_to_cart", add_args)
        again = Array.new(2) { run.("dup-add", "add_to_cart", add_args) }
        order = world.call_log.reload.order
        add_demo = { "deliveries" => 3, "identical_stored_result" => again.all?(first), "order_lines" => order.order_items.count, "cart_version" => order.cart_version,
                     "replay_count" => world.call_log.tool_invocations.find_by!(tool_call_id: "dup-add").replay_count }

        run.("dup-cart", "get_cart")
        read_at = order.reload.read_back_at
        run.("dup-add2", "add_to_cart", { "menu_item_id" => world.item_id("Garlic Knots") })
        stale = JSON.parse(run.("dup-cart", "get_cart"))
        order.reload
        cart_demo = { "original_read_back_version" => 1, "cart_version_after_a_change" => order.cart_version, "duplicate_get_cart_returned_version" => stale["cart_version"],
                      "read_back_version_after_duplicate" => order.read_back_version, "read_back_at_unchanged" => order.read_back_at == read_at,
                      "submit_with_current_version_refused_as" => JSON.parse(run.("dup-sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => order.cart_version })).dig("error", "code") }

        run.("dup-cart2", "get_cart")
        submit_args = { "fulfillment_type" => "pickup", "cart_version" => order.reload.cart_version }
        s1 = run.("dup-sub2", "submit_order", submit_args, Evaluation.answered_history("dup-sub2")) # the caller answered the read-back
        s2 = run.("dup-sub2", "submit_order", submit_args, Evaluation.answered_history("dup-sub2"))
        s3 = JSON.parse(run.("dup-sub3", "submit_order", submit_args)) # no history: an already-submitted order stays idempotent
        placed = order.reload.placed_at
        submit_demo = { "same_id_twice_identical" => s1 == s2, "new_id_answer" => { "already_submitted" => s3["already_submitted"], "confirmation_sms" => s3["confirmation_sms"] },
                        "order_status" => order.status, "placed_at_set_once" => placed.present?, "submit_rows" => world.call_log.tool_invocations.where(tool_name: "submit_order").count }

        result = { "duplicate_add_to_cart" => add_demo, "late_duplicate_get_cart" => cart_demo, "duplicate_submit_order" => submit_demo,
                   "threaded_duplicate_delivery" => "covered by test/services/voice/tool_runner_concurrency_test.rb (real threads on committed data); not re-run here" }
        raise ActiveRecord::Rollback # nothing persists: the scenario ran inside a rolled-back transaction
      end
      result
    end

    # --- the suite ---

    def suite
      commands = { "full_test_suite" => %w[bin/rails test], "replay_suite" => %w[bin/rails test test/baseline/live_call_replay_test.rb],
                   "baseline_verify_frozen_originals_against_the_tag" => %w[bin/rails baseline:verify] }
      counts = commands.transform_values do |command|
        output, status = Open3.capture2e({ "RAILS_ENV" => "test" }, *command)
        line = output[/^\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips/] || output[/\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips/]
        numbers = line ? line.scan(/\d+/).map(&:to_i) : []
        { "command" => command.join(" "), "passed" => status.success?, "runs" => numbers[0], "assertions" => numbers[1], "failures" => numbers[2], "errors" => numbers[3], "skips" => numbers[4] }
      end
      { "generated_at" => Time.current.iso8601, "git" => git_state, "results" => counts,
        "not_included" => "RuboCop, Brakeman, bundler-audit and importmap audit are run separately and reported in the commit/step reports." }
    end

    def manifest(names)
      {
        "generated_at" => Time.current.iso8601, "git" => git_state, "ruby" => RUBY_VERSION, "rails" => Rails.version, "env" => Rails.env,
        "regenerate" => "RAILS_ENV=test bin/rails evidence:generate   (and evidence:suite for test counts)",
        "live_evidence" => {
          "status" => "PARTIAL",
          "recorded_in" => "docs/voice_agent/verification_log.md (one real browser call, call #8, 2026-09-30, and vapi:check against the live dev assistant)",
          "still_pending" => [ "a scripted set of live calls beyond the first (plan Step 16: 5-8 calls)", "live-model garlic-knots sample (plan Layer 3a, N=20, baseline vs new prompt)",
                               "a live call with a real phone number (SMS path)" ]
        },
        "files" => names.to_h { |name| [ name, Digest::SHA256.file(DIR.join(name)).hexdigest ] }
      }
    end

    def git_state
      sha, = Open3.capture2("git", "-C", Rails.root.to_s, "rev-parse", "--short", "HEAD")
      dirty, = Open3.capture2("git", "-C", Rails.root.to_s, "status", "--porcelain", "--untracked-files=no")
      { "commit" => sha.strip, "uncommitted_tracked_changes" => !dirty.strip.empty? }
    end
  end
end

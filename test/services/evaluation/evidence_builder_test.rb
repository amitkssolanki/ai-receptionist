require "test_helper"
require "tmpdir"

# The code that builds docs/phase1/evidence (normally run through `bin/rails evidence:generate` / `evidence:suite`), exercised
# directly: each generated file must equal what a fresh run produces (apart from wall-clock timings), generate must write a
# manifest whose hashes match what it wrote, and the suite summary must be read honestly. evidence_test.rb checks the
# committed files themselves.
class Evaluation::EvidenceBuilderTest < ActiveSupport::TestCase
  RESULTS = Evaluation::Runner.run_all.freeze
  DIR = Evaluation::Evidence::DIR

  def committed(name) = JSON.parse(DIR.join(name).read)

  test "the idempotency and cart-version evidence rebuilt from a fresh run equals the committed file" do
    fresh = JSON.parse(Evaluation::Evidence.idempotency(RESULTS).to_json)
    assert_equal committed("idempotency_and_versions.json"), fresh,
                 "docs/phase1/evidence is stale: run RAILS_ENV=test bin/rails evidence:generate and commit the result"
  end

  test "the duplicate submit demo uses a caller-answered history and shows one execution, then an idempotent answer" do
    demo = JSON.parse(Evaluation::Evidence.duplicate_demos.to_json)["duplicate_submit_order"]
    # submit rows: the stale-version refusal, the confirmed submit (its duplicate delivery is replayed onto the same row), the idempotent answer
    assert_equal [ true, "confirmed", true, 3 ], demo.values_at("same_id_twice_identical", "order_status", "placed_at_set_once", "submit_rows")
    assert_equal({ "already_submitted" => true, "confirmation_sms" => nil }, demo["new_id_answer"])

    history = Evaluation.answered_history("s-1")["messages"]
    assert_equal %w[tool_call_result user tool_calls], history.map { |m| m["role"] }
    assert Voice::TurnEvidence.caller_turn_after_read_back?(Voice::TurnEvidence.for_submit({ "messages" => history }, tool_call_id: "s-1"))
  end

  test "the latency evidence has one ordered row per tool that ran, with the same run counts as the committed file" do
    fresh = Evaluation::Evidence.latency(RESULTS)
    committed_rows = committed("latency.json")["after_phase1"]

    assert_equal committed_rows.keys, fresh["after_phase1"].keys
    fresh["after_phase1"].each do |tool, row|
      assert_equal committed_rows.dig(tool, "runs"), row["runs"], tool
      assert_operator row["min_ms"], :<=, row["median_ms"], tool
      assert_operator row["median_ms"], :<=, row["max_ms"], tool
    end
    assert_equal %w[add_to_cart get_cart get_menu submit_order], fresh["baseline_one_sample_for_reference"].keys.sort - [ "note" ]
    assert_equal committed("latency.json").except("after_phase1", "measured_on").keys.sort, fresh.except("after_phase1", "measured_on").keys.sort
  end

  test "generate writes every evidence file and a manifest whose hashes match what it wrote, without touching the committed files" do
    before = DIR.children.sort.to_h { |path| [ path.basename.to_s, Digest::SHA256.file(path).hexdigest ] }

    Dir.mktmpdir do |dir|
      written = Evaluation::Evidence.generate(dir: dir)
      assert_equal %w[garlic_knots_probe.json latency.json idempotency_and_versions.json manifest.json], written

      manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
      assert_equal written - [ "manifest.json" ], manifest["files"].keys
      manifest["files"].each { |name, digest| assert_equal Digest::SHA256.file(File.join(dir, name)).hexdigest, digest, name }
      assert_equal "PARTIAL", manifest.dig("live_evidence", "status")

      probe = JSON.parse(File.read(File.join(dir, "garlic_knots_probe.json")))
      assert_equal RESULTS.size, probe.dig("totals", "scenarios")
      assert_equal committed("idempotency_and_versions.json"), JSON.parse(File.read(File.join(dir, "idempotency_and_versions.json")))
    end

    assert_equal before, DIR.children.sort.to_h { |path| [ path.basename.to_s, Digest::SHA256.file(path).hexdigest ] }
  end

  # evidence:suite runs the real suites in subprocesses; here the subprocess is replaced so the summary parsing can be checked.
  def with_captured_commands(outputs)
    calls = []
    original = Open3.method(:capture2e)
    Open3.define_singleton_method(:capture2e) do |env, *command|
      calls << [ env, command.join(" ") ]
      output, ok = outputs.fetch(command.join(" "))
      [ output, Struct.new(:ok) { def success? = ok }.new(ok) ]
    end
    yield calls
  ensure
    Open3.define_singleton_method(:capture2e, original)
  end

  test "suite reports each command's summary line and whether it passed, and never invents counts" do
    outputs = {
      "bin/rails test" => [ "Running…\n\n398 runs, 3450 assertions, 0 failures, 0 errors, 2 skips\n", true ],
      "bin/rails test test/baseline/live_call_replay_test.rb" => [ "6 runs, 613 assertions, 1 failures, 0 errors, 0 skips\n", false ],
      "bin/rails baseline:verify" => [ "could not create the worktree\n", false ]
    }
    body = with_captured_commands(outputs) do |calls|
      result = Evaluation::Evidence.suite
      assert_equal outputs.keys, calls.map(&:last)
      assert(calls.all? { |env, _| env == { "RAILS_ENV" => "test" } }, "every command runs in the test environment")
      result
    end
    results = body["results"]

    assert_equal [ true, 398, 3450, 0, 0, 2 ], results["full_test_suite"].values_at("passed", "runs", "assertions", "failures", "errors", "skips")
    assert_equal [ false, 6, 1 ], results["replay_suite"].values_at("passed", "runs", "failures")
    assert_equal [ false, nil, nil ], results["baseline_verify_frozen_originals_against_the_tag"].values_at("passed", "runs", "failures")
    assert_match(/\A\h+\z/, body.dig("git", "commit"))
    assert_includes [ true, false ], body.dig("git", "uncommitted_tracked_changes")
  end
end

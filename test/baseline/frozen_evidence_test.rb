require "test_helper"
require "rake"

# CI guard for the frozen Phase 0 evidence (see lib/tasks/baseline.rake). The full re-run against the tag is
# `bin/rails baseline:verify`, which needs the tag and git history.
class FrozenEvidenceTest < ActiveSupport::TestCase
  test "frozen baseline evidence is byte-identical to SHA256SUMS" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("baseline:manifest")
    assert_empty Baseline.manifest_problems
  end
end

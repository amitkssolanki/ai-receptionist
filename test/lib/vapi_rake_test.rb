require "test_helper"
require "rake"

# vapi:check's PROFILE handling. Both cases stop before any network call (the test environment has no Vapi credentials).
class VapiRakeTest < ActiveSupport::TestCase
  setup { Rails.application.load_tasks unless Rake::Task.task_defined?("vapi:check") }

  def run_check(profile)
    Rake::Task["vapi:check"].reenable
    ENV["PROFILE"] = profile
    error = nil
    _out, err = capture_io { error = assert_raises(SystemExit) { Rake::Task["vapi:check"].invoke } }
    [ error, err ]
  ensure
    ENV.delete("PROFILE")
  end

  test "PROFILE=fault_injection without a configured assistant id says which setting is missing" do
    error, err = run_check("fault_injection")
    assert_not error.success?
    assert_match(/no fault_injection assistant id is configured \(VAPI_FAULT_INJECTION_ASSISTANT_ID or credentials vapi\.fault_injection_assistant_id\)/, err)
  end

  test "an unknown profile is refused" do
    error, err = run_check("production")
    assert_not error.success?
    assert_match(/unknown Vapi profile "production"/, err)
  end
end

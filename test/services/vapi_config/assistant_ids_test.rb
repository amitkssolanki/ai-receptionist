require "test_helper"

# Which assistant the console calls. VAPI_ASSISTANT_ID is the environment-neutral name production sets; the older local
# name VAPI_DEV_ASSISTANT_ID keeps working. The fault-injection assistant is a development and test instrument: in
# production it is never configured, whatever the environment says.
class VapiConfig::AssistantIdsTest < ActiveSupport::TestCase
  NAMES = %w[VAPI_ASSISTANT_ID VAPI_DEV_ASSISTANT_ID VAPI_FAULT_INJECTION_ASSISTANT_ID VAPI_PUBLIC_KEY].freeze
  ASSISTANT = "11111111-0000-0000-0000-000000000001".freeze # explicit dummy ids, not real assistants
  DEV_ASSISTANT = "22222222-0000-0000-0000-000000000002".freeze
  FAULT_ASSISTANT = "33333333-0000-0000-0000-000000000003".freeze

  setup { @before = NAMES.to_h { |k| [ k, ENV.delete(k) ] } }
  teardown { @before.each { |k, v| v ? ENV[k] = v : ENV.delete(k) } }

  def in_env(env)
    before = Rails.env
    Rails.env = env
    yield
  ensure
    Rails.env = before
  end

  test "VAPI_ASSISTANT_ID is the console's assistant, ahead of the older VAPI_DEV_ASSISTANT_ID" do
    ENV["VAPI_DEV_ASSISTANT_ID"] = DEV_ASSISTANT
    assert_equal DEV_ASSISTANT, VapiConfig.dev_assistant_id
    ENV["VAPI_ASSISTANT_ID"] = ASSISTANT
    assert_equal ASSISTANT, VapiConfig.dev_assistant_id
    assert_equal ASSISTANT, VapiConfig.profile("development").assistant_id
  end

  test "without any assistant id the console names VAPI_ASSISTANT_ID as the setting to fill in" do
    ENV["VAPI_PUBLIC_KEY"] = "pk-test-public-0000"
    assert_match(/VAPI_ASSISTANT_ID/, VapiConfig.browser_problems.join)
  end

  test "the fault-injection assistant works in development and test" do
    ENV["VAPI_FAULT_INJECTION_ASSISTANT_ID"] = FAULT_ASSISTANT
    assert_equal FAULT_ASSISTANT, VapiConfig.fault_injection_assistant_id
    in_env("development") { assert_equal FAULT_ASSISTANT, VapiConfig.fault_injection_assistant_id }
  end

  test "in production the fault-injection assistant is never configured, and its console cannot start" do
    ENV["VAPI_FAULT_INJECTION_ASSISTANT_ID"] = FAULT_ASSISTANT
    ENV["VAPI_ASSISTANT_ID"] = ASSISTANT
    ENV["VAPI_PUBLIC_KEY"] = "pk-test-public-0000"
    in_env("production") do
      assert_nil VapiConfig.fault_injection_assistant_id
      assert_nil VapiConfig.profile("fault_injection").assistant_id
      assert_equal [ "The fault-injection assistant is development-only and is never used in production." ],
                   VapiConfig.browser_problems("fault_injection")
      assert_empty VapiConfig.browser_problems("development")
    end
  end
end

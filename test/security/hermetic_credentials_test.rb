require "test_helper"

class HermeticCredentialsTest < ActiveSupport::TestCase
  test "the test process never sees the developer's Vapi credentials" do
    %i[private_key public_key dev_assistant_id server_secret].each do |key|
      assert_nil Rails.application.credentials.dig(:vapi, key), "vapi.#{key} leaked into the test environment"
    end
    assert_nil VapiConfig.private_key
    assert_nil VapiConfig.public_key
    assert_nil VapiConfig.dev_assistant_id
    assert_nil VapiConfig.webhook_secret
    assert_nil VapiConfig.fault_injection_assistant_id
  end

  test "the Rails secret key base is still available (only vapi.* is hidden)" do
    assert_predicate Rails.application.secret_key_base, :present?
    # Where the encrypted credentials can be read (a developer machine with the master key), their other keys survive the
    # hiding. CI has no master key, so there is nothing to decrypt there.
    assert_predicate Rails.application.credentials.secret_key_base, :present? if Rails.application.credentials.key.present?
  end
end

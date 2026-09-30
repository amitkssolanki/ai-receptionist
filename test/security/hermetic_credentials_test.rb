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
  end

  test "the Rails secret key base is still available (only vapi.* is hidden)" do
    assert_predicate Rails.application.credentials.secret_key_base, :present?
  end
end

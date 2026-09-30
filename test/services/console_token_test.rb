require "test_helper"

class ConsoleTokenTest < ActiveSupport::TestCase
  setup { @restaurant = Restaurant.create!(name: "Token Bistro", phone_number: "+15550004545") }

  test "a token round-trips to its restaurant and session key" do
    key = SecureRandom.hex(8)
    verified = ConsoleToken.verify(ConsoleToken.issue(restaurant: @restaurant, session_key: key))
    assert_equal [ @restaurant, key ], [ verified[:restaurant], verified[:session_key] ]
  end

  test "tokens expire after 15 minutes" do
    token = ConsoleToken.issue(restaurant: @restaurant, session_key: SecureRandom.hex(8))
    travel(14.minutes) { assert ConsoleToken.verify(token) }
    travel(16.minutes) { assert_nil ConsoleToken.verify(token) }
  end

  test "anything that is not exactly our token is nil, never an error" do
    [ nil, "", "x", 5, {}, [], "a.b", "#{'A' * 200}--#{'b' * 40}" ].each { |bad| assert_nil ConsoleToken.verify(bad), bad.inspect }
  end

  test "a token for a deleted restaurant is nil" do
    token = ConsoleToken.issue(restaurant: @restaurant, session_key: SecureRandom.hex(8))
    @restaurant.destroy
    assert_nil ConsoleToken.verify(token)
  end

  test "the session key must look like the ones the console generates" do
    bad = Rails.application.message_verifier(:vapi_console).generate({ "restaurant_id" => @restaurant.id, "session_key" => "../../etc" }, purpose: :vapi_console)
    assert_nil ConsoleToken.verify(bad)
  end
end

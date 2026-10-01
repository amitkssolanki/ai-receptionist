require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  Warden = Struct.new(:user)

  setup do
    @restaurant = Restaurant.create!(name: "Cable Bistro", phone_number: "+15550008181")
    @user = User.create!(email: "cable@example.com", password: "password123", restaurant: @restaurant)
  end

  test "a signed-in admin can connect" do
    connect env: { "warden" => Warden.new(@user) }
    assert_equal @user, connection.current_user
  end

  test "no session is rejected" do
    assert_reject_connection { connect env: { "warden" => Warden.new(nil) } }
    assert_reject_connection { connect }
  end
end

class ConsoleChannelTest < ActionCable::Channel::TestCase
  tests ConsoleChannel

  setup do
    @restaurant = Restaurant.create!(name: "Mine", phone_number: "+15550008282")
    @other_restaurant = Restaurant.create!(name: "Theirs", phone_number: "+15550008383")
    @user = User.create!(email: "mine@example.com", password: "password123", restaurant: @restaurant)
    @mine = make_call(@restaurant, "mine_call")
    @theirs = make_call(@other_restaurant, "theirs_call")
    stub_connection current_user: @user
  end

  def make_call(restaurant, id)
    restaurant.call_logs.create!(external_call_id: id, customer: restaurant.customers.create!(phone_number: "unknown-#{id}"), phone_number: "unknown-#{id}")
  end

  def signed(*streamables) = Turbo::StreamsChannel.signed_stream_name(streamables)

  test "the user can follow their own restaurant's call" do
    subscribe signed_stream_name: signed(@mine, :console)
    assert subscription.confirmed?
    assert_has_stream Turbo::StreamsChannel.verified_stream_name(signed(@mine, :console))
  end

  test "a validly signed stream name for ANOTHER restaurant's call is refused: a call id is not a credential" do
    subscribe signed_stream_name: signed(@theirs, :console)
    assert subscription.rejected?
  end

  test "an unsigned, forged or missing stream name is refused" do
    subscribe signed_stream_name: "#{@mine.to_gid_param}:console"
    assert subscription.rejected?
    subscribe signed_stream_name: "not-signed--abc"
    assert subscription.rejected?
    subscribe
    assert subscription.rejected?
  end

  test "streams the console does not own are refused, even when validly signed" do
    [ [ "room" ], [ @mine, :something_else ], [ :console_session ], [ @other_restaurant, :console ], [ @mine, :console, :extra ], [ @user, :console ] ].each do |streamables|
      subscribe signed_stream_name: signed(*streamables)
      assert subscription.rejected?, streamables.inspect
    end
  end

  test "a console session stream is open to a signed-in admin who holds its signed name" do
    subscribe signed_stream_name: signed(:console_session, SecureRandom.hex(16))
    assert subscription.confirmed?
  end

  test "a call that no longer exists is refused" do
    name = signed(@mine, :console)
    @mine.destroy
    subscribe signed_stream_name: name
    assert subscription.rejected?
  end
end

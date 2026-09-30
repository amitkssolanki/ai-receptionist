require "test_helper"

class Admin::ConsoleControllerTest < ActionDispatch::IntegrationTest
  PUBLIC_KEY = "pk-test-public-0000".freeze            # explicit dummy values, not credentials
  PRIVATE_KEY = "TEST-PRIVATE-KEY-MUST-NOT-RENDER".freeze
  SERVER_SECRET = "0123456789abcdef0123456789abcdef".freeze

  setup do
    @restaurant = Restaurant.create!(name: "Console Bistro", phone_number: "+15550005151")
    @user = User.create!(email: "console@example.com", password: "password123", restaurant: @restaurant)
    @env_before = %w[VAPI_PUBLIC_KEY VAPI_DEV_ASSISTANT_ID VAPI_PRIVATE_KEY VAPI_SERVER_SECRET].to_h { |k| [ k, ENV[k] ] }
    ENV["VAPI_PRIVATE_KEY"] = PRIVATE_KEY
    ENV["VAPI_SERVER_SECRET"] = SERVER_SECRET
  end

  teardown { @env_before.each { |k, v| v ? ENV[k] = v : ENV.delete(k) } }

  def configure!
    ENV["VAPI_PUBLIC_KEY"] = PUBLIC_KEY
    ENV["VAPI_DEV_ASSISTANT_ID"] = "11111111-2222-3333-4444-555555555555"
  end

  def unconfigure!
    ENV.delete("VAPI_PUBLIC_KEY")
    ENV.delete("VAPI_DEV_ASSISTANT_ID")
  end

  # --- authentication ---

  test "the console requires sign-in" do
    get admin_console_path
    assert_redirected_to new_user_session_path
    post admin_console_token_path, params: { session_key: "a" * 32 }
    assert_redirected_to new_user_session_path
    get admin_console_call_path(1)
    assert_redirected_to new_user_session_path
  end

  test "a signed-in user sees the console" do
    configure!
    sign_in @user
    get admin_console_path
    assert_response :success
    assert_select "[data-controller~=voice-console]"
    assert_select "button[data-action='voice-console#start']:not([disabled])"
    assert_select "button[data-action='voice-console#end'][disabled]"
    assert_select "#console-setup", count: 0
    assert_match(/source: VAPI \(client\)/, response.body)
  end

  # --- configuration seam ---

  test "without a public key or assistant id the page says what to configure and cannot start a call" do
    unconfigure!
    sign_in @user
    get admin_console_path
    assert_response :success
    assert_select "#console-setup li", count: 2
    assert_select "button[data-action='voice-console#start'][disabled]"
    assert_select "[data-voice-console-public-key-value]", count: 0
  end

  test "the frozen baseline assistant is refused as the console's assistant" do
    configure!
    ENV["VAPI_DEV_ASSISTANT_ID"] = VapiConfig::BASELINE_ASSISTANT_ID
    sign_in @user
    get admin_console_path
    assert_select "#console-setup", text: /frozen baseline/
    assert_select "button[data-action='voice-console#start'][disabled]"
    assert_no_match(/#{VapiConfig::BASELINE_ASSISTANT_ID}/, response.body)
  end

  test "only the public key and assistant id reach the browser; never the private key or the webhook secret" do
    configure!
    sign_in @user
    get admin_console_path
    assert_includes response.body, PUBLIC_KEY
    assert_includes response.body, "11111111-2222-3333-4444-555555555555"
    assert_no_match(/#{PRIVATE_KEY}|#{SERVER_SECRET}|X-Vapi-Secret|VAPI_PRIVATE_KEY|VAPI_SERVER_SECRET/, response.body)
  end

  test "the page carries a session key but no pre-issued token" do
    configure!
    sign_in @user
    get admin_console_path
    key = css_select("[data-voice-console-session-key-value]").first["data-voice-console-session-key-value"]
    assert_match(/\A[0-9a-f]{32}\z/, key)
    assert_no_match(/console_token|vapi_console/, response.body, "no console token in the HTML: it is fetched when the call starts")
    get admin_console_path
    other = css_select("[data-voice-console-session-key-value]").first["data-voice-console-session-key-value"]
    assert_not_equal key, other, "a new session key per page"
  end

  # --- token ---

  test "the token endpoint issues a fresh signed token bound to the user's restaurant and the session key" do
    sign_in @user
    key = SecureRandom.hex(16)
    post admin_console_token_path, params: { session_key: key }, as: :json
    assert_response :success
    verified = ConsoleToken.verify(JSON.parse(response.body)["token"])
    assert_equal [ @restaurant, key ], [ verified[:restaurant], verified[:session_key] ]
  end

  test "the token endpoint rejects malformed session keys" do
    sign_in @user
    [ "", "short", "../../x", "g" * 32, "a" * 100 ].each do |bad|
      post admin_console_token_path, params: { session_key: bad }, as: :json
      assert_response :unprocessable_entity, bad.inspect
    end
  end

  test "a token is bound to the requesting user's restaurant, never another's" do
    other = Restaurant.create!(name: "Other", phone_number: "+15550006161")
    sign_in @user
    post admin_console_token_path, params: { session_key: SecureRandom.hex(16), restaurant_id: other.id }, as: :json
    assert_equal @restaurant, ConsoleToken.verify(JSON.parse(response.body)["token"])[:restaurant]
  end

  # --- call page ---

  test "a call page shows only calls of the user's own restaurant" do
    customer = @restaurant.customers.create!(phone_number: "unknown-mine")
    mine = @restaurant.call_logs.create!(external_call_id: "mine", customer: customer, phone_number: "unknown-mine", transcript: "AI: hello")
    other = Restaurant.create!(name: "Other", phone_number: "+15550006262")
    theirs = other.call_logs.create!(external_call_id: "theirs", customer: other.customers.create!(phone_number: "unknown-theirs"), phone_number: "unknown-theirs")
    sign_in @user

    get admin_console_call_path(mine)
    assert_response :success
    assert_match(/AI: hello/, response.body)

    get admin_console_call_path(theirs)
    assert_response :not_found
  end
end

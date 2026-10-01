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

  # --- fallback attach by call id ---

  def make_call(restaurant, external_id)
    restaurant.call_logs.create!(external_call_id: external_id, customer: restaurant.customers.create!(phone_number: "unknown-#{external_id}"), phone_number: "unknown-#{external_id}")
  end

  test "attach needs sign-in" do
    post admin_console_attach_path, params: { call_id: "x" }, as: :json
    assert_response :unauthorized
  end

  test "attach answers with the call's panels and its stream when the call is the user's restaurant's" do
    call = make_call(@restaurant, "019fd4fa-attach-1")
    sign_in @user
    post admin_console_attach_path, params: { call_id: call.external_call_id }, as: :json

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action=update][target=console-call]" do
      assert_select "template turbo-cable-stream-source[channel=ConsoleChannel]", count: 1
      assert_select "template turbo-frame#call-state[src='#{admin_console_call_state_path(call)}']"
      assert_select "template turbo-frame#call-events[src='#{admin_console_call_state_path(call)}']"
      assert_select "template [data-attached-via=call_id]"
    end
  end

  test "attach says pending, identically, for a call that does not exist yet and for another restaurant's call" do
    other = Restaurant.create!(name: "Other", phone_number: "+15550009292")
    theirs = make_call(other, "theirs-attach")
    sign_in @user

    post admin_console_attach_path, params: { call_id: "not-here-yet" }, as: :json
    assert_response :accepted
    unknown_body = response.body
    post admin_console_attach_path, params: { call_id: theirs.external_call_id }, as: :json
    assert_response :accepted
    assert_equal unknown_body, response.body, "no way to tell 'not yours' from 'not there'"
    assert_no_match(/#{theirs.id}/, response.body)
  end

  test "attach rejects malformed call ids" do
    sign_in @user
    [ "", "a b", "x" * 101, "../etc", "id;drop" ].each do |bad|
      post admin_console_attach_path, params: { call_id: bad }, as: :json
      assert_response :unprocessable_entity, bad.inspect
    end
  end

  test "the console page wires the fallback: attach url and the call-created action" do
    configure!
    sign_in @user
    get admin_console_path
    root = css_select("[data-controller~=voice-console]").first
    assert_equal admin_console_attach_path, root["data-console-sync-attach-url-value"]
    assert_includes root["data-action"], "voice-console:call-created->console-sync#attachFallback"
  end
end

require "test_helper"

# The public homepage at /. It is static: anyone can read it, it reads no records and no configuration values, and every
# way into the product it offers (the console, the dashboard) still goes through sign-in.
class HomeControllerTest < ActionDispatch::IntegrationTest
  PUBLIC_KEY = "pk-home-test-0000".freeze # explicit dummy values, not credentials
  SERVER_SECRET = "0123456789abcdef0123456789abcdef".freeze
  PRIVATE_KEY = "TEST-PRIVATE-KEY-MUST-NOT-RENDER".freeze
  ASSISTANT_ID = "44444444-0000-0000-0000-000000000004".freeze
  VARIABLES = { "VAPI_PUBLIC_KEY" => PUBLIC_KEY, "VAPI_SERVER_SECRET" => SERVER_SECRET, "VAPI_PRIVATE_KEY" => PRIVATE_KEY,
                "VAPI_ASSISTANT_ID" => ASSISTANT_ID, "VAPI_FAULT_INJECTION_ASSISTANT_ID" => ASSISTANT_ID }.freeze

  setup do
    @before = VARIABLES.keys.to_h { |k| [ k, ENV[k] ] }
    VARIABLES.each { |k, v| ENV[k] = v }
    @restaurant = Restaurant.create!(name: "Private Bistro", phone_number: "+15550007070")
    @user = User.create!(email: "home@example.com", password: "password123", restaurant: @restaurant)
    customer = @restaurant.customers.create!(phone_number: "+15551237070")
    @restaurant.orders.create!(customer: customer, fulfillment_type: :pickup, status: :confirmed)
    @restaurant.call_logs.create!(external_call_id: "home_call", customer: customer, phone_number: "+15551237070", transcript: "AI: private transcript")
  end

  teardown { @before.each { |k, v| v ? ENV[k] = v : ENV.delete(k) } }

  test "anyone can read the homepage" do
    get root_path
    assert_response :success
    assert_select "h1", text: /The model proposes\.\s*The server decides\./
    assert_select "title", text: /AI Restaurant Receptionist/
  end

  test "link previews get an absolute 1200x630 image that exists" do
    get root_path
    assert_select "meta[property='og:image'][content='http://www.example.com/og.png']"
    assert_select "meta[property='og:image:width'][content='1200']"
    assert_select "meta[name='twitter:card'][content='summary_large_image']"
    png = Rails.root.join("public/og.png").binread
    assert_equal "\x89PNG".b, png[0, 4]
    assert_equal [ 1200, 630 ], png[16, 8].unpack("NN")
  end

  test "it explains the thesis with the real evidence: a call, the garlic knots and the refused submit" do
    get root_path
    assert_select "#how-it-works h2"
    assert_select "#source-of-truth blockquote", text: /I'll add garlic knots/
    assert_select "#source-of-truth", text: /not in the order/
    assert_select "#reliability", text: /customer_confirmation_required/
    assert_select "img[src*='console-call-22']"
    assert_select "img[src*='confirmation-gate-call-20']"
  end

  test "it renders no secret, key, assistant id or private record" do
    get root_path
    [ PUBLIC_KEY, SERVER_SECRET, PRIVATE_KEY, ASSISTANT_ID, @restaurant.name, "+15551237070", "private transcript", @user.email ].each do |value|
      assert_not_includes response.body, value
    end
    assert_select "[data-voice-console-public-key-value]", count: 0
  end

  test "an anonymous visitor is sent to sign-in, never straight to the console or the dashboard" do
    get root_path
    assert_select "a[href='#{new_user_session_path}']", minimum: 2
    assert_select "a[href='#{admin_console_path}']", count: 0
    assert_select "a[href='#{admin_root_path}']", count: 0
  end

  test "a signed-in operator gets the console and the dashboard from the homepage" do
    sign_in @user
    get root_path
    assert_response :success
    assert_select "a[href='#{admin_console_path}']", text: "Open the voice console", minimum: 2
    assert_select "a[href='#{admin_root_path}']", text: "Dashboard"
    assert_not_includes response.body, PUBLIC_KEY
  end

  test "every in-page link points at a section that exists" do
    get root_path
    anchors = css_select("a[href^='#']").map { |a| a["href"].delete_prefix("#") }.uniq
    assert_not_empty anchors
    anchors.each { |id| assert_select "##{id}", { minimum: 1 }, "no element with id #{id}" }
  end

  test "signing in from the homepage lands on the dashboard, which is now /admin" do
    post user_session_path, params: { user: { email: @user.email, password: "password123" } }
    assert_redirected_to admin_root_path
    follow_redirect!
    assert_response :success
    assert_select "h1", text: @restaurant.name
  end
end

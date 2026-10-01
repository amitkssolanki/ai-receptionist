require "test_helper"

# The pre-deployment boundary. An anonymous visitor must not be able to start a paid Vapi/LLM call, change any state or read
# admin data. Every route is either an Admin::BaseController action (Devise sign-in, then scoped to the user's restaurant)
# or on the public list below with a reason. The Vapi webhook is a server-to-server boundary with its own secret
# (webhook_security_test.rb), and the cable connection needs a signed-in session (console_channel_test.rb).
class AnonymousBoundaryTest < ActionDispatch::IntegrationTest
  PUBLIC = {
    "users/sessions#new" => "the sign-in form",
    "users/sessions#create" => "sign-in itself, rate-limited",
    "users/sessions#destroy" => "sign-out",
    "rails/health#show" => "liveness: 200 or 500, no data",
    "api/vapi/webhooks#create" => "server to server: X-Vapi-Secret, fails closed",
    "turbo/native/navigation#recede" => "Turbo Native history redirect, no data",
    "turbo/native/navigation#resume" => "Turbo Native history redirect, no data",
    "turbo/native/navigation#refresh" => "Turbo Native history redirect, no data"
  }.freeze

  # Framework routes that exist but answer nothing outside development: no Action Mailbox ingress is configured (404), and
  # the mailbox conductor is development-only (403).
  INERT = %w[action_mailbox/ingresses/ rails/conductor/].freeze

  PUBLIC_KEY = "pk-boundary-test-0000".freeze # explicit dummy values, not credentials
  SERVER_SECRET = "0123456789abcdef0123456789abcdef".freeze

  setup do
    @restaurant = Restaurant.create!(name: "Boundary Bistro", phone_number: "+15550006060", business_hours: ALWAYS_OPEN_HOURS)
    @user = User.create!(email: "boundary@example.com", password: "password123", restaurant: @restaurant)
    @category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @item = @category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @modifier = @item.menu_item_modifiers.create!(name: "Cheese", price_cents: 100)
    customer = @restaurant.customers.create!(phone_number: "+15551236060")
    @order = @restaurant.orders.create!(customer: customer, fulfillment_type: :pickup, status: :confirmed)
    @call_log = @restaurant.call_logs.create!(external_call_id: "boundary_call", customer: customer, phone_number: "+15551236060")

    @env_before = %w[VAPI_PUBLIC_KEY VAPI_DEV_ASSISTANT_ID VAPI_SERVER_SECRET].to_h { |k| [ k, ENV[k] ] }
    ENV["VAPI_PUBLIC_KEY"] = PUBLIC_KEY
    ENV["VAPI_DEV_ASSISTANT_ID"] = "11111111-2222-3333-4444-555555555555"
    ENV["VAPI_SERVER_SECRET"] = SERVER_SECRET
  end

  teardown { @env_before.each { |k, v| v ? ENV[k] = v : ENV.delete(k) } }

  # Every application route with a controller, as [verb, path spec, "controller#action"].
  def app_routes
    Rails.application.routes.routes.filter_map do |route|
      controller, action = route.defaults.values_at(:controller, :action)
      [ route.verb, route.path.spec.to_s, "#{controller}##{action}" ] if controller
    end
  end

  def admin_routes = app_routes.select { |_, _, key| key.start_with?("admin/") }

  # A concrete URL for a route, with real ids of this test's records.
  def url_for_route(spec, key)
    ids = { "admin/menu_categories" => @category, "admin/menu_items" => @item, "admin/menu_item_modifiers" => @modifier,
            "admin/orders" => @order, "admin/call_logs" => @call_log, "admin/console" => @call_log }
    spec.sub("(.:format)", "")
        .gsub(":menu_category_id", @category.id.to_s)
        .gsub(":menu_item_id", @item.id.to_s)
        .gsub(":id", ids.fetch(key.split("#").first, @call_log).id.to_s)
  end

  MUTATION_PARAMS = {
    menu_category: { name: "Anon category" }, menu_item: { name: "Anon item", price_cents: 1 },
    menu_item_modifier: { name: "Anon modifier", price_cents: 1 }, order: { status: "cancelled" },
    restaurant: { name: "Anon Bistro" }, session_key: "a" * 32, call_id: "boundary_call"
  }.freeze

  def snapshot
    [ Restaurant, User, MenuCategory, MenuItem, MenuItemModifier, Customer, Order, OrderItem, CallLog, ToolInvocation ]
      .to_h { |model| [ model.name, model.order(:id).map(&:attributes) ] }
  end

  def assert_sign_in_required(label)
    assert response.status == 401 || (response.redirect? && response.location == new_user_session_url),
           "#{label} answered #{response.status} #{response.location} without a session"
  end

  # --- 1. the route inventory ---

  test "every route is behind sign-in unless it is on the public list" do
    app_routes.each do |verb, spec, key|
      next if PUBLIC.key?(key) || INERT.any? { |prefix| key.start_with?(prefix) }

      klass = "#{key.split('#').first.camelize}Controller".constantize
      assert klass <= Admin::BaseController, "#{verb} #{spec} (#{key}) is reachable without signing in"
    end
  end

  test "no admin controller skips or narrows the sign-in check" do
    Rails.application.eager_load!
    Admin::BaseController.descendants.each do |klass|
      callback = klass._process_action_callbacks.find { |cb| cb.kind == :before && cb.filter == :authenticate_user! }
      assert callback, "#{klass} does not run authenticate_user!"
      assert_empty callback.instance_variable_get(:@if), "#{klass} runs authenticate_user! only conditionally"
      assert_empty callback.instance_variable_get(:@unless), "#{klass} skips authenticate_user! for some actions"
    end
  end

  test "password reset and Active Storage are not routed at all" do
    keys = app_routes.map(&:last)
    assert_empty keys.grep(%r{\Adevise/passwords#}), "anonymous password reset would write a token and send mail"
    assert_empty keys.grep(%r{\Aactive_storage/}), "Active Storage direct uploads would accept anonymous blobs"
    assert_not_respond_to @user, :send_reset_password_instructions

    post "/users/password", params: { user: { email: @user.email } }
    assert_response :not_found
    post "/rails/active_storage/direct_uploads", params: { blob: { filename: "x.txt", byte_size: 1, checksum: "x", content_type: "text/plain" } }
    assert_response :not_found
  end

  # --- 2. anonymous requests: rejected, and nothing changes ---

  test "every admin route rejects an anonymous request, whatever the verb, and no state changes" do
    before = snapshot
    admin_routes.each do |verb, spec, key|
      url = url_for_route(spec, key)
      process verb.downcase.to_sym, url, params: MUTATION_PARAMS
      assert_sign_in_required("#{verb} #{url}")
    end
    assert_equal before, snapshot
  end

  test "JSON and Turbo Stream requests from an anonymous browser get 401, not data" do
    post admin_console_token_path, params: { session_key: "a" * 32 }, as: :json
    assert_response :unauthorized
    assert_not_includes response.body, "token\":"

    post admin_console_attach_path, params: { call_id: "boundary_call" }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_sign_in_required("console attach (turbo stream)")
    assert_not_includes response.body, "boundary_call"
  end

  test "the root and admin pages show no restaurant, order or call data to an anonymous visitor" do
    [ root_path, admin_orders_path, admin_order_path(@order), admin_call_logs_path, admin_console_call_state_path(@call_log) ].each do |path|
      get path
      assert_sign_in_required(path)
      assert_not_includes response.body, @restaurant.name
      assert_not_includes response.body, "+15551236060"
    end
  end

  # --- 3. paid operations ---

  test "an anonymous visitor never receives the Vapi public key or a console token, so cannot start a browser call" do
    get admin_console_path
    assert_sign_in_required("console")
    assert_not_includes response.body, PUBLIC_KEY

    get admin_console_path(assistant: "fault_injection")
    assert_not_includes response.body, PUBLIC_KEY

    post admin_console_token_path, params: { session_key: "a" * 32 }
    assert_sign_in_required("console token")
    assert_not_includes response.body, "token"

    # Positive control: the same page, signed in, does render the key (the browser SDK needs it to start a call).
    sign_in @user
    get admin_console_path
    assert_response :success
    assert_includes response.body, PUBLIC_KEY
  end

  test "an anonymous or wrong-secret webhook cannot run a tool, change an order or send an SMS" do
    before = snapshot
    submit = { type: "tool-calls", call: { id: "boundary_call" },
               toolCallList: [ { id: "anon_submit", function: { name: "submit_order", arguments: { cart_version: 1 } } } ],
               artifact: VapiHistory.answered("anon_submit") }
    start = { type: "status-update", status: "in-progress", call: { id: "anon_new_call", type: "webCall" } }

    assert_no_enqueued_jobs do
      [ {}, { "X-Vapi-Secret" => "wrong-secret-0123456789" }, { "X-Vapi-Secret" => "" } ].each do |headers|
        [ submit, start ].each do |message|
          post api_vapi_webhooks_path, params: { message: message }, headers: headers, as: :json
          assert_response :unauthorized
          assert_empty response.body
        end
      end
    end
    assert_equal before, snapshot
  end

  test "the configured webhook secret is still accepted" do
    post api_vapi_webhooks_path, params: { message: { type: "status-update", status: "in-progress", call: { id: "ok_call", type: "webCall" } } },
                                 headers: { "X-Vapi-Secret" => SERVER_SECRET }, as: :json
    assert_response :ok
  end

  # --- 4. what stays public ---

  test "the health check stays public and says nothing about the application" do
    get rails_health_check_path
    assert_response :success
    [ @restaurant.name, PUBLIC_KEY, SERVER_SECRET, "admin", "vapi" ].each { |text| assert_not_includes response.body.downcase, text.downcase }
  end

  test "the sign-in page stays public and offers no sign-up or password reset" do
    get new_user_session_path
    assert_response :success
    assert_select "a[href*='password']", count: 0
    assert_select "a[href*='sign_up']", count: 0
  end

  test "the inert framework routes answer nothing" do
    post "/rails/action_mailbox/relay/inbound_emails", params: { raw: "x" }
    assert_response :not_found
    get "/rails/conductor/action_mailbox/inbound_emails"
    assert_response :forbidden
  end

  # --- 5. authenticated workflows still work ---

  test "a signed-in admin can open every admin page" do
    sign_in @user
    admin_routes.select { |verb, spec, _| verb == "GET" }.each do |_, spec, key|
      url = url_for_route(spec, key)
      get url
      assert_response :success, "GET #{url}"
    end
  end

  test "a signed-in admin can still change state" do
    sign_in @user
    patch admin_restaurant_path, params: { restaurant: { name: "Renamed Bistro" } }
    assert_equal "Renamed Bistro", @restaurant.reload.name
    post admin_console_token_path, params: { session_key: "a" * 32 }, as: :json
    assert_response :success
    assert response.parsed_body["token"].present?
  end
end

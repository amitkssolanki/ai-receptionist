require "test_helper"

# Step 10: the webhook secret has no default and fails closed; payloads and exception text stay out of the logs.
class Api::Vapi::WebhookSecurityTest < ActionDispatch::IntegrationTest
  SECRET = "0123456789abcdef0123456789abcdef".freeze # explicit test value, not a real credential

  setup do
    @original_secret = ENV.delete("VAPI_SERVER_SECRET")
    @restaurant = Restaurant.create!(name: "Sec Bistro", phone_number: "+15550002121", business_hours: ALWAYS_OPEN_HOURS)
    @restaurant.menu_categories.create!(name: "Mains", position: 1).menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @log = StringIO.new
    @original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log)
  end

  teardown do
    Rails.logger = @original_logger
    @original_secret ? ENV["VAPI_SERVER_SECRET"] = @original_secret : ENV.delete("VAPI_SERVER_SECRET")
  end

  def post_event(message, secret: SECRET)
    headers = secret ? { "X-Vapi-Secret" => secret } : {}
    post api_vapi_webhooks_path, params: { message: message }, headers: headers, as: :json
  end

  def status_update(id = "sec_call") = { type: "status-update", status: "in-progress", call: { id: id, type: "webCall" } }

  # --- the secret ---

  test "with no secret configured every request is refused, whatever it sends, and the reason is logged" do
    [ SECRET, "", "dev-secret-change-me", "anything" ].each do |sent|
      post_event(status_update, secret: sent)
      assert_response :unauthorized, sent.inspect
    end
    post_event(status_update, secret: nil)
    assert_response :unauthorized
    assert_equal 0, CallLog.count
    assert_match(/VAPI_SERVER_SECRET is missing/, @log.string)
  end

  test "a secret shorter than 16 characters counts as not configured" do
    ENV["VAPI_SERVER_SECRET"] = "short"
    post_event(status_update, secret: "short")
    assert_response :unauthorized
    assert_equal 0, CallLog.count
  end

  test "the known old default is never accepted, even when a real secret is configured" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    post_event(status_update, secret: "dev-secret-change-me")
    assert_response :unauthorized
  end

  test "a wrong or missing secret is rejected when one is configured" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    post_event(status_update, secret: "#{SECRET[0..-2]}x")
    assert_response :unauthorized
    post_event(status_update, secret: nil)
    assert_response :unauthorized
    post_event(status_update, secret: SECRET + "extra")
    assert_response :unauthorized
    assert_equal 0, CallLog.count
  end

  test "the configured secret is accepted and the event is processed" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    post_event(status_update)
    assert_response :success
    assert_equal 1, CallLog.count
  end

  test "the secret can come from credentials when the env var is absent" do
    credentials = Rails.application.credentials
    original = credentials.method(:dig)
    credentials.define_singleton_method(:dig) { |*keys| keys == [ :vapi, :server_secret ] ? SECRET : original.call(*keys) }
    begin
      post_event(status_update)
      assert_response :success
      post_event(status_update("other_call"), secret: "wrong-wrong-wrong-wrong")
      assert_response :unauthorized
    ensure
      credentials.define_singleton_method(:dig, original)
    end
  end

  test "a failed authentication never reaches the tools and returns no body" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    post_event({ type: "tool-calls", call: { id: "x" }, toolCallList: [ { id: "t", function: { name: "get_menu", arguments: {} } } ] }, secret: "nope")
    assert_response :unauthorized
    assert_empty response.body
  end

  # --- logging ---

  PHONE = "SENSITIVE_PHONE_987654".freeze
  TRANSCRIPT = "SENSITIVE_TRANSCRIPT_ABC123".freeze
  MARKER_SECRET = "SENSITIVE_SECRET_XYZ789".freeze

  test "no payload value reaches the log: phone, transcript, provider URLs, credentials or metadata" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    post_event({ type: "status-update", status: "in-progress",
                 call: { id: "log_call", type: "webCall", phoneNumber: { number: PHONE }, customer: { number: PHONE },
                         monitor: { listenUrl: "https://#{MARKER_SECRET}.example/listen", controlUrl: "https://#{MARKER_SECRET}.example/control" },
                         transport: { provider: "daily", callUrl: "https://#{MARKER_SECRET}.example/room" } },
                 customer: { number: PHONE, name: "SENSITIVE_NAME" }, metadata: { apiKey: MARKER_SECRET } })
    post_event({ type: "tool-calls", call: { id: "log_call" }, customer: { number: PHONE },
                 toolCallList: [ { id: "tc_1", function: { name: "add_to_cart", arguments: { menu_item_id: @restaurant.menu_items.first.id, notes: TRANSCRIPT } } } ] })
    post_event({ type: "end-of-call-report", call: { id: "log_call" }, customer: { number: PHONE },
                 artifact: { transcript: TRANSCRIPT, messages: [ { message: TRANSCRIPT } ], recording: { stereoUrl: "https://#{MARKER_SECRET}.example/rec.wav" } },
                 endedReason: "customer-ended-call", cost: 0.42 })

    assert_response :success
    assert_no_match(/SENSITIVE_/, @log.string)
    assert_no_match(/#{Regexp.escape(SECRET)}/, @log.string)
    assert_match(/\[Vapi\] event type=status-update call=log_call/, @log.string)
    assert_match(/\[Vapi\] event type=tool-calls call=log_call/, @log.string)
    assert_match(/\[Vapi\] tool-calls call=log_call add_to_cart#tc_1=ok/, @log.string)
    assert_match(/\[Vapi\] event type=end-of-call-report call=log_call/, @log.string)
  end

  test "Rails' own request log filters the webhook body" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("message" => { "type" => "x", "customer" => { "number" => PHONE } }, "artifact" => { "transcript" => TRANSCRIPT })
    assert_equal({ "message" => "[FILTERED]", "artifact" => "[FILTERED]" }, filtered)
    %w[transcript customer phoneNumber monitor transport].each do |key|
      assert_equal "[FILTERED]", filter.filter(key => "SENSITIVE")[key], key
    end
    assert_equal "[FILTERED]", filter.filter("x_vapi_secret" => "v")["x_vapi_secret"]
  end

  test "the full request log (Rails' Parameters line included) holds no marker" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    Rails.logger = ActiveSupport::Logger.new(@log) # already set; Rails' subscribers log through Rails.logger
    ActionController::Base.logger = Rails.logger
    ActionController::API.logger = Rails.logger if ActionController::API.respond_to?(:logger=)
    post_event(status_update.merge(customer: { number: PHONE }, artifact: { transcript: TRANSCRIPT }))
    assert_match(/Processing by Api::Vapi::WebhooksController#create/, @log.string, "the framework's request log was captured")
    assert_match(/Parameters: \{"message" => "\[FILTERED\]"/, @log.string)
    assert_no_match(/SENSITIVE_/, @log.string)
  ensure
    ActionController::Base.logger = @original_logger
    ActionController::API.logger = @original_logger
  end

  test "log values from the payload are reduced to one short safe token (no log injection)" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    post_event({ type: "status-update\n[Vapi] forged line", status: "in-progress", call: { id: "id\r\nFORGED #{"x" * 500}" } })
    lines = @log.string.lines.grep(/\[Vapi\] event/)
    assert_equal 1, lines.size
    assert_operator lines.first.length, :<, 200
    assert_no_match(/^FORGED|^\[Vapi\] forged/, @log.string)
  end

  # --- error hygiene ---

  test "an unexpected exception is logged as class and location only, and the model gets internal_error" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    post_event(status_update("err_call"))
    original = Order.instance_method(:recompute_total!)
    Order.define_method(:recompute_total!) { |*, **| raise "leaks SENSITIVE_PHONE_987654 and sk_live_SENSITIVE_KEY" }
    begin
      post_event({ type: "tool-calls", call: { id: "err_call" }, toolCallList: [ { id: "boom", function: { name: "add_to_cart", arguments: { menu_item_id: @restaurant.menu_items.first.id } } } ] })
    ensure
      Order.define_method(:recompute_total!, original)
    end

    body = response.body
    result = JSON.parse(JSON.parse(body)["results"].first["result"])
    assert_equal "internal_error", result.dig("error", "code")
    assert_no_match(/SENSITIVE|sk_live|RuntimeError/, body)
    assert_no_match(/SENSITIVE|sk_live/, @log.string)
    assert_match(/tool add_to_cart failed on call err_call: RuntimeError at /, @log.string)
    assert_equal "RuntimeError", ToolInvocation.find_by!(tool_call_id: "boom").error_class
    assert_no_match(/SENSITIVE|sk_live/, ToolInvocation.find_by!(tool_call_id: "boom").result)
  end

  test "a failed audit write is logged without the database's error message" do
    ENV["VAPI_SERVER_SECRET"] = SECRET
    post_event(status_update("audit_call"))
    original = ToolInvocation.method(:record!)
    ToolInvocation.define_singleton_method(:record!) { |**| raise ActiveRecord::StatementInvalid, "duplicate key value (phone_number)=(SENSITIVE_PHONE_987654)" }
    begin
      post_event({ type: "tool-calls", call: { id: "audit_call" }, toolCallList: [ { id: "a1", function: { name: "get_menu", arguments: {} } } ] })
    ensure
      ToolInvocation.define_singleton_method(:record!, original)
    end
    assert_response :success
    assert_no_match(/SENSITIVE/, @log.string)
    assert_match(/could not record tool invocation a1; served unrecorded: ActiveRecord::StatementInvalid/, @log.string)
  end
end

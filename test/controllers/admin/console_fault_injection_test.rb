require "test_helper"
require "rake"

# Phase 2: the opt-in fault-injection console (/admin/console?assistant=fault_injection), its red label, and how a
# refused premature submit from that assistant reads on the console and in calls:last. The default console is unchanged.
class Admin::ConsoleFaultInjectionTest < ActionDispatch::IntegrationTest
  PUBLIC_KEY = "pk-test-public-0000".freeze                # explicit dummy values, not credentials
  DEV_ID = "11111111-2222-3333-4444-555555555555".freeze
  FAULT_ID = "99999999-8888-7777-6666-555555555555".freeze
  ENV_KEYS = %w[VAPI_PUBLIC_KEY VAPI_DEV_ASSISTANT_ID VAPI_FAULT_INJECTION_ASSISTANT_ID].freeze

  setup do
    @env_before = ENV_KEYS.to_h { |k| [ k, ENV[k] ] }
    ENV["VAPI_PUBLIC_KEY"] = PUBLIC_KEY
    ENV["VAPI_DEV_ASSISTANT_ID"] = DEV_ID
    ENV["VAPI_FAULT_INJECTION_ASSISTANT_ID"] = FAULT_ID
    @restaurant = Restaurant.create!(name: "Fault Bistro", phone_number: "+15550006262", business_hours: ALWAYS_OPEN_HOURS)
    @burger = @restaurant.menu_categories.create!(name: "Mains", position: 1).menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    sign_in User.create!(email: "fault@example.com", password: "password123", restaurant: @restaurant)
  end

  teardown { @env_before.each { |k, v| v ? ENV[k] = v : ENV.delete(k) } }

  def assistant_attribute = css_select("[data-voice-console-assistant-id-value]").first&.attribute("data-voice-console-assistant-id-value")&.value

  # --- the console page ---

  test "the default console is unchanged: the development assistant, no banner" do
    get admin_console_path
    assert_equal DEV_ID, assistant_attribute
    assert_select "#fault-injection-banner", count: 0
    assert_no_match(/#{FAULT_ID}|FAULT INJECTION/, response.body)
  end

  test "?assistant=fault_injection calls the fault-injection assistant under a red banner" do
    get admin_console_path(assistant: "fault_injection")
    assert_equal FAULT_ID, assistant_attribute
    assert_select "#fault-injection-banner", text: /FAULT INJECTION · deliberately misconfigured test assistant/
    assert_select "#fault-injection-banner", text: /The server, its tools and its rules are exactly the same/
    assert_select "button[data-action='voice-console#start']:not([disabled])"
    assert_no_match(/#{DEV_ID}/, response.body)
  end

  test "an unconfigured fault-injection assistant never falls back to the development assistant" do
    ENV.delete("VAPI_FAULT_INJECTION_ASSISTANT_ID")
    get admin_console_path(assistant: "fault_injection")
    assert_select "#console-setup", text: /No fault-injection assistant id is configured/
    assert_select "button[data-action='voice-console#start'][disabled]"
    assert_nil assistant_attribute
    assert_no_match(/#{DEV_ID}/, response.body)
  end

  test "the development or baseline assistant is refused as the fault-injection assistant" do
    [ DEV_ID, VapiConfig::BASELINE_ASSISTANT_ID ].each do |id|
      ENV["VAPI_FAULT_INJECTION_ASSISTANT_ID"] = id
      get admin_console_path(assistant: "fault_injection")
      assert_select "#console-setup", text: /must be a separate assistant/
      assert_nil assistant_attribute
    end
  end

  # --- a refused premature submit, as the console shows it ---

  def call_with_premature_submit(external_id, assistant_id)
    call_log = CallLifecycle.start(external_call_id: external_id, dialed_number: @restaurant.phone_number, caller_number: nil, assistant_id: assistant_id)
    run = ->(id, name, args = {}, artifact = nil) { Voice::ToolRunner.call(call_log: call_log, tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } }, artifact: artifact) }
    run.("add", "add_to_cart", { "menu_item_id" => @burger.id })
    run.("cart", "get_cart")
    run.("submit", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 },
         VapiHistory.for_submit("submit", caller_turns: 0, get_cart_id: "cart", same_completion: true))
    call_log
  end

  test "a fault-injection call's refusal reads within seconds: label, reason, zero caller turns, unchanged order" do
    call_log = call_with_premature_submit("fault_call", FAULT_ID)
    get admin_console_call_state_path(call_log)
    assert_response :success

    assert_select "#call-status [data-fault-injection]", text: "FAULT INJECTION · test assistant"
    assert_select "#tool_call_submit", text: /⛔ rejected · customer_confirmation_required/
    assert_select "#tool_call_submit", text: /0 caller turns since the last get_cart; nothing was submitted, v1 kept/
    assert_select "#tool_call_submit", text: /confirmation gate: submit refused \(no caller turn after the read-back\)/
    assert_select "#order-board[data-order-status=pending][data-cart-version='1']"
    assert_select "#order-board", text: /submit refused: waiting for the caller's answer to the read-back \(v1\)/
    assert_equal [ "pending", 1, nil ], [ call_log.order.reload.status, call_log.order.cart_version, call_log.order.placed_at ]
  end

  test "a development-assistant call carries no fault-injection label" do
    call_log = call_with_premature_submit("normal_call", DEV_ID)
    get admin_console_call_state_path(call_log)
    assert_select "[data-fault-injection]", count: 0
    assert_select "#tool_call_submit", text: /customer_confirmation_required/
  end

  test "calls:last labels a fault-injection call, and only that" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("calls:last")
    summary = lambda do |call_log|
      Rake::Task["calls:last"].reenable
      ENV["CALL"] = call_log.id.to_s
      capture_io { Rake::Task["calls:last"].invoke }.first
    ensure
      ENV.delete("CALL")
    end

    fault = summary.(call_with_premature_submit("fault_rake", FAULT_ID))
    assert_match(/\Acall #\d+ .*FAULT INJECTION \(test assistant\)$/, fault.lines.first)
    assert_match(/submit_order\s+rejected/, fault)
    assert_no_match(/FAULT INJECTION/, summary.(call_with_premature_submit("normal_rake", DEV_ID)))
  end
end

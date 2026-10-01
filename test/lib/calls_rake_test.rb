require "test_helper"
require "rake"

class CallsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("calls:last")
    @restaurant = Restaurant.create!(name: "Rake Bistro", phone_number: "+15550003535", business_hours: ALWAYS_OPEN_HOURS)
    @burger = @restaurant.menu_categories.create!(name: "Mains", position: 1).menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @call = CallLifecycle.start(external_call_id: "rake_1", dialed_number: @restaurant.phone_number, caller_number: "+15557774321")
  end

  def output
    Rake::Task["calls:last"].reenable
    ENV["CALL"] = @call.id.to_s
    capture_io { Rake::Task["calls:last"].invoke }.first
  ensure
    ENV.delete("CALL")
  end

  test "the summary shows the call, its tool calls with versions, and the order, and no phone number or payload" do
    Voice::ToolRunner.call(call_log: @call, tool_call: { "id" => "t1", "function" => { "name" => "add_to_cart", "arguments" => { "menu_item_id" => @burger.id, "notes" => "SENSITIVE_NOTE" } } })
    text = output

    assert_match(/call ##{@call.id}\s+in_progress/, text)
    assert_match(/add_to_cart\s+ok\s+v0→v1/, text)
    assert_match(/order: #\d+ CART OPEN v1 \$10\.00/, text)
    assert_match(/1 x Burger/, text)
    assert_no_match(/SENSITIVE_NOTE|\+1555777|unknown-/, text)
  end

  test "it says so when a console session attached the call" do
    @call.update!(console_session_key: SecureRandom.hex(16))
    assert_match(/console session: yes \(token arrived\)/, output)
  end
end

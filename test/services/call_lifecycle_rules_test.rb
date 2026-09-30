require "test_helper"

# Step 8: the documented call status rules (see the comment at the top of CallLifecycle), one test per transition.
class CallLifecycleRulesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @restaurant = Restaurant.create!(name: "Rules Life", phone_number: "+15550009595", business_hours: ALWAYS_OPEN_HOURS)
    @burger = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                         .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @call = CallLifecycle.start(external_call_id: "rules_life", dialed_number: @restaurant.phone_number, caller_number: nil)
  end

  def finish(transcript: "AI: bye") = CallLifecycle.finish(external_call_id: "rules_life", transcript: transcript, recording_url: nil)
  def add = OrderTaking.new(@call.reload).add_item(menu_item_id: @burger.id)
  def order = @call.reload.order

  def submit
    OrderTaking.new(@call.reload).read_back
    OrderTaking.new(@call.reload).submit(fulfillment_type: "pickup", cart_version: order.cart_version)
  end

  test "open -> abandoned: no order at all" do
    finish
    assert_predicate @call.reload, :abandoned?
    assert_predicate @call.ended_at, :present?
  end

  test "open -> abandoned: an open cart is abandoned with its items kept" do
    add
    finish
    assert_predicate @call.reload, :abandoned?
    assert_predicate order, :abandoned?
    assert_equal [ 1, 1000 ], [ order.order_items.count, order.total_cents ]
  end

  test "open -> completed: a submitted order is never abandoned, however far the kitchen got" do
    add
    submit
    %i[confirmed preparing ready].each_with_index do |status, i|
      order.update!(status: status) unless order.status == status.to_s
      call = CallLifecycle.start(external_call_id: "rules_life_#{i}", dialed_number: @restaurant.phone_number, caller_number: nil)
      call.update!(order: order)
      CallLifecycle.finish(external_call_id: "rules_life_#{i}", transcript: nil, recording_url: nil)
      assert_predicate call.reload, :completed?, status
      assert_predicate order.reload.status, :present?
      assert_equal status.to_s, order.status
    end
  end

  test "open -> transferred -> finish: stays transferred; an open cart is still abandoned" do
    add
    CallLifecycle.transfer(@call, "wants a person")
    finish
    assert_predicate @call.reload, :transferred?
    assert_equal "wants a person", @call.transfer_reason
    assert_predicate @call.ended_at, :present?
    assert_predicate order, :abandoned?
  end

  test "transferred -> finish with a submitted order: still transferred, order untouched" do
    add
    submit
    CallLifecycle.transfer(@call, "question about allergens")
    finish
    assert_predicate @call.reload, :transferred?
    assert_predicate order, :confirmed?
  end

  test "open -> finish -> transfer: transferred outranks abandoned and completed; the order is not revived" do
    add
    finish
    assert_predicate order, :abandoned?
    CallLifecycle.transfer(@call.reload, "late transfer")
    assert_predicate @call.reload, :transferred?
    assert_equal "late transfer", @call.transfer_reason
    assert_predicate order, :abandoned?

    other = CallLifecycle.start(external_call_id: "rules_done", dialed_number: @restaurant.phone_number, caller_number: nil)
    OrderTaking.new(other).add_item(menu_item_id: @burger.id)
    OrderTaking.new(other.reload).read_back
    OrderTaking.new(other.reload).submit(fulfillment_type: "pickup", cart_version: 1)
    CallLifecycle.finish(external_call_id: "rules_done", transcript: nil, recording_url: nil)
    assert_predicate other.reload, :completed?
    CallLifecycle.transfer(other, "after the fact")
    assert_predicate other.reload, :transferred?
    assert_predicate other.order, :confirmed?
  end

  test "a repeated finish changes nothing: first report wins, no second abandon, no SMS" do
    add
    finish(transcript: "first")
    ended_at = @call.reload.ended_at
    order_updated = order.updated_at
    sms_before = enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }

    travel(1.hour) { 3.times { finish(transcript: "duplicate") } }

    assert_equal [ "first", ended_at, "abandoned" ], [ @call.reload.transcript, @call.ended_at, @call.status ]
    assert_equal order_updated, order.updated_at
    assert_equal sms_before, enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }
  end

  test "a repeated finish after a confirmed order never abandons it and sends no further SMS" do
    add
    assert_enqueued_jobs 1, only: OrderConfirmationSmsJob do
      submit
      3.times { finish }
    end
    assert_predicate @call.reload, :completed?
    assert_predicate order, :confirmed?
  end

  test "a second transfer is a no-op" do
    CallLifecycle.transfer(@call, "first")
    at = @call.reload.transferred_at
    travel(1.minute) { CallLifecycle.transfer(@call, "second") }
    assert_equal [ "first", at ], [ @call.reload.transfer_reason, @call.transferred_at ]
  end

  test "a long transfer reason is capped" do
    CallLifecycle.transfer(@call, "x" * 5000)
    assert_equal CallLifecycle::REASON_LIMIT, @call.reload.transfer_reason.length
  end

  test "an ended call accepts no cart changes but can still be transferred through the tool runner" do
    finish
    result = JSON.parse(Voice::ToolRunner.call(call_log: @call.reload, tool_call: { "id" => "late_add", "function" => { "name" => "add_to_cart", "arguments" => { "menu_item_id" => @burger.id } } }))
    assert_equal "no_active_call", result.dig("error", "code")
    assert_equal 0, Order.count

    Voice::ToolRunner.call(call_log: @call.reload, tool_call: { "id" => "late_transfer", "function" => { "name" => "transfer_to_human", "arguments" => { "reason" => "late" } } })
    assert_predicate @call.reload, :transferred?
  end

  test "start: a duplicate returns nil and changes nothing; customers are shared per restaurant and number" do
    assert_nil CallLifecycle.start(external_call_id: "rules_life", dialed_number: @restaurant.phone_number, caller_number: nil)
    first = CallLifecycle.start(external_call_id: "s1", dialed_number: @restaurant.phone_number, caller_number: "+15557771111")
    second = CallLifecycle.start(external_call_id: "s2", dialed_number: @restaurant.phone_number, caller_number: "+15557771111")
    assert_equal first.customer, second.customer
  end

  test "lifecycle operations take the call lock before the order lock and never the reverse" do
    add
    statements = lambda do |&block|
      locks = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        locks << payload[:sql][/FROM "(\w+)"/, 1] if payload[:sql].include?("FOR UPDATE")
      end
      block.call
      ActiveSupport::Notifications.unsubscribe(sub)
      locks
    end

    operations = {
      "tool get_cart" => -> { Voice::ToolRunner.call(call_log: @call.reload, tool_call: { "id" => "lk", "function" => { "name" => "get_cart", "arguments" => {} } }) },
      "transfer" => -> { CallLifecycle.transfer(@call.reload, "x") },
      "finish" => -> { finish },
      "finish again" => -> { finish }
    }
    operations.each do |name, op|
      locks = statements.call(&op)
      assert_equal locks.sort_by { |t| t == "call_logs" ? 0 : 1 }, locks, "#{name} locked #{locks.inspect}: an orders lock must never precede a call_logs lock"
      assert_includes locks, "call_logs", name
      assert_includes locks, "orders", name if [ "tool get_cart", "finish" ].include?(name)
    end
  end
end

require "test_helper"

# Step 9: browser/synthetic callers never trigger an SMS (an explicit, non-failing skip); real callers get exactly one,
# queued only after the order transaction commits; and no SMS problem can undo or disturb a confirmed order.
class SmsGuardTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  REAL = "+15557771234".freeze

  setup do
    @restaurant = Restaurant.create!(name: "Sms Bistro", phone_number: "+15550006767", business_hours: ALWAYS_OPEN_HOURS)
    @burger = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                         .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @log = StringIO.new
    @original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log)
  end

  teardown { Rails.logger = @original_logger }

  def start(id, caller_number) = CallLifecycle.start(external_call_id: id, dialed_number: @restaurant.phone_number, caller_number: caller_number)

  # submit_order carries a history in which the caller answered the read-back (the confirmation gate's input, see
  # VapiHistory); the gate itself is tested in test/controllers/api/vapi/confirmation_gate_test.rb.
  def run_tool(call, id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(call.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } },
                           artifact: VapiHistory.for_tool(name, id))
  end

  def confirm(call, prefix = "c")
    run_tool(call, "#{prefix}_add", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool(call, "#{prefix}_cart", "get_cart")
    JSON.parse(run_tool(call, "#{prefix}_sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }))
  end

  def sms_jobs = enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }

  test "which customers can be texted" do
    { "+15557771234" => true, "+447911123456" => true, "unknown-019fd4fa-7f12" => false, "" => false, "5557771234" => false,
      "+0123456789" => false, "+1555" => false, "+155577712345678901" => false, "anonymous" => false }.each do |number, expected|
      assert_equal expected, Customer.new(phone_number: number).sms_capable?, number.inspect
    end
  end

  test "a browser call confirms its order, queues no SMS, and says so explicitly" do
    call = start("web_1", nil)
    assert_predicate call.customer.phone_number, :present?
    result = confirm(call)

    assert_equal true, result["ok"]
    assert_not result.key?("confirmation_sms"), "the model hears nothing about a text that was not sent"
    assert_predicate call.reload.order, :confirmed?
    assert_equal 0, sms_jobs
    assert_match(/\[SMS\] skipped confirmation for order #{call.order.id}: caller has no SMS-capable number/, @log.string)
    assert_equal "not sent: web call, no phone number", ConsoleView::Board.new(call).sms, "visible to the console, derived from server state"
  end

  # SMS boundary: the model is told about a confirmation text only when one was queued. The internal "skipped_web_call"
  # (and the old "already_handled") led the agent to talk about texts it should not mention (live calls #2 and #6).
  test "the model-facing submit result never exposes internal SMS state" do
    web = start("boundary_web", nil)
    run_tool(web, "boundary_web_add", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool(web, "boundary_web_cart", "get_cart")
    web_result = run_tool(web, "boundary_web_sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })
    repeat = run_tool(web, "boundary_web_again", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })
    phone = start("boundary_phone", REAL)
    run_tool(phone, "boundary_phone_add", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool(phone, "boundary_phone_cart", "get_cart")
    phone_result = run_tool(phone, "boundary_phone_sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })

    [ web_result, repeat ].each do |raw|
      assert_no_match(/skipped_web_call|already_handled|confirmation_sms|web call|phone number/, raw)
    end
    assert_equal [ true, true ], [ JSON.parse(web_result)["ok"], JSON.parse(repeat)["already_submitted"] ]
    assert_equal "queued", JSON.parse(phone_result)["confirmation_sms"], "a queued text is still reported"
    assert_no_match(/skipped_web_call/, web.tool_invocations.map(&:result).join, "the audit row stores what the model was told")
    assert_equal [ "not sent: web call, no phone number", "confirmation text queued" ], [ web, phone ].map { |c| ConsoleView::Board.new(c.reload).sms }
  end

  test "a caller with a real number gets exactly one SMS queued" do
    call = start("phone_1", REAL)
    result = confirm(call)
    assert_equal "queued", result["confirmation_sms"]
    assert_equal 1, sms_jobs
    assert_equal [ call.reload.order.id ], enqueued_jobs.select { |j| j["job_class"] == "OrderConfirmationSmsJob" }.flat_map { |j| j["arguments"] }
  end

  test "a duplicate delivery, a repeated submit with a new id, and a replayed get_cart queue no second SMS" do
    call = start("phone_2", REAL)
    first = confirm(call)
    assert_equal "queued", first["confirmation_sms"]

    travel(1.minute) do
      assert_equal first, JSON.parse(run_tool(call, "c_sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })), "same toolCallId: stored result"
      again = JSON.parse(run_tool(call, "c_sub_again", "submit_order", { "fulfillment_type" => "delivery", "delivery_address" => "1 Main St", "cart_version" => 1 }))
      assert_equal [ true, false ], [ again["already_submitted"], again.key?("confirmation_sms") ]
      run_tool(call, "c_cart", "get_cart")
    end
    assert_equal 1, sms_jobs
    assert_predicate call.reload.order, :pickup?
    assert_nil call.order.delivery_address
  end

  test "finish (once or repeated) and transfer queue no SMS, before or after confirmation" do
    call = start("phone_3", REAL)
    confirm(call)
    assert_equal 1, sms_jobs

    3.times { CallLifecycle.finish(external_call_id: "phone_3", transcript: "x", recording_url: nil) }
    run_tool(call, "xfer", "transfer_to_human", { "reason" => "question" })
    assert_equal 1, sms_jobs
    assert_predicate call.reload.order, :confirmed?

    unconfirmed = start("phone_4", REAL)
    run_tool(unconfirmed, "u_add", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool(unconfirmed, "u_xfer", "transfer_to_human", { "reason" => "wants a person" })
    CallLifecycle.finish(external_call_id: "phone_4", transcript: nil, recording_url: nil)
    assert_equal 1, sms_jobs, "a transferred/abandoned call never texts"
  end

  test "no phone number or provider detail is written to the log" do
    confirm(start("web_2", nil))
    confirm(start("phone_5", REAL))
    assert_no_match(/\+1555777|1234/, @log.string)
  end

  test "the job refuses to text a synthetic number even if it is enqueued by mistake" do
    customer = @restaurant.customers.create!(phone_number: "unknown-web_3")
    order = @restaurant.orders.create!(customer: customer, fulfillment_type: :pickup, status: :confirmed)
    order.order_items.create!(menu_item: @burger, quantity: 1, unit_price_cents: 1000)
    sent = []
    fake = Object.new
    fake.define_singleton_method(:messages) { self }
    fake.define_singleton_method(:create) { |**args| sent << args }
    ENV.update("TWILIO_ACCOUNT_SID" => "AC_test", "TWILIO_AUTH_TOKEN" => "token", "TWILIO_FROM_NUMBER" => "+15550009999")
    original = Twilio::REST::Client.method(:new)
    Twilio::REST::Client.define_singleton_method(:new) { |*| fake }
    begin
      OrderConfirmationSmsJob.perform_now(order.id)
    ensure
      Twilio::REST::Client.define_singleton_method(:new, original)
      %w[TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_FROM_NUMBER].each { |k| ENV.delete(k) }
    end
    assert_empty sent
    assert_match(/skipped confirmation for order #{order.id}/, @log.string)
  end
end

# Real commits (transactions off) so "after commit" and "enqueue failure" are the real thing.
class SmsGuardCommitTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    @restaurant = Restaurant.create!(name: "Commit Bistro", phone_number: "+15550006868", business_hours: ALWAYS_OPEN_HOURS)
    @burger = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                         .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @call = CallLifecycle.start(external_call_id: "commit_1", dialed_number: @restaurant.phone_number, caller_number: "+15557771234")
    @log = StringIO.new
    @original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@log)
  end

  teardown do
    Rails.logger = @original_logger
    ActiveJob::Base.queue_adapter = :test
    [ ToolInvocation, CallLog, OrderItem, Order, Customer, MenuItem, MenuCategory, Restaurant ].each(&:delete_all)
  end

  # submit_order carries a history in which the caller answered the read-back (the confirmation gate's input, see
  # VapiHistory); the gate itself is tested in test/controllers/api/vapi/confirmation_gate_test.rb.
  def run_tool(id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(@call.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } },
                           artifact: VapiHistory.for_tool(name, id))
  end

  def submit
    run_tool("add", "add_to_cart", { "menu_item_id" => @burger.id })
    run_tool("cart", "get_cart")
    run_tool("sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })
  end

  def sms_jobs = enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }

  test "the SMS is enqueued only after the transaction commits" do
    order = nil
    ApplicationRecord.transaction do
      order = @restaurant.orders.create!(customer: @call.customer, fulfillment_type: :pickup)
      OrderConfirmationSmsJob.enqueue_after_commit(order)
      assert_equal 0, sms_jobs, "nothing is queued while the transaction is open"
    end
    assert_equal 1, sms_jobs

    ApplicationRecord.transaction do
      OrderConfirmationSmsJob.enqueue_after_commit(order)
      raise ActiveRecord::Rollback
    end
    assert_equal 1, sms_jobs, "a rolled-back transaction queues nothing"
  end

  test "through the tool path: submit queues one SMS, and only once the order is committed" do
    result = JSON.parse(submit)
    assert_equal "queued", result["confirmation_sms"]
    assert_equal 1, sms_jobs
    assert_predicate Order.find(@call.reload.order_id), :confirmed?
  end

  test "an enqueue failure never undoes or alters the confirmed order, and leaks nothing to the model" do
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.define_singleton_method(:enqueue) { |*| raise "queue down: redis://user:secret@10.0.0.9 for +15557771234" }

    raw = submit
    result = JSON.parse(raw)

    assert_equal true, result["ok"]
    assert_equal "queued", result["confirmation_sms"], "the order's own outcome is unchanged"
    assert_predicate Order.find(@call.reload.order_id), :confirmed?
    assert_no_match(/queue down|redis|secret|10\.0\.0\.9|\+1555/, raw)
    row = @call.tool_invocations.find_by!(tool_call_id: "sub")
    assert_equal [ "ok", nil ], [ row.status, row.error_class ]
    assert_match(/\[SMS\] could not enqueue confirmation for order #{@call.order_id}: RuntimeError/, @log.string)
    assert_no_match(/queue down|secret|\+1555|10\.0\.0\.9/, @log.string, "neither the exception text nor the number is logged")
  end
end

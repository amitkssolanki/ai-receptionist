require "test_helper"
require "timeout"

# Real threads on committed data (as in the Step 7 tests): lifecycle events and tool calls must never make
# contradictory decisions about one call/order. No sleeps; ordering comes from the database locks.
class CallLifecycleConcurrencyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    @restaurant = Restaurant.create!(name: "Race Life", phone_number: "+15550008989", business_hours: ALWAYS_OPEN_HOURS)
    category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @seq = 0
  end

  teardown do
    [ ToolInvocation, CallLog, OrderItem, Order, Customer, MenuItem, MenuCategory, Restaurant ].each(&:delete_all)
  end

  def new_call = CallLifecycle.start(external_call_id: "life_race_#{@seq += 1}", dialed_number: @restaurant.phone_number, caller_number: "+1555777#{format("%04d", @seq)}")

  def tool(call, id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(call.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } })
  end

  def finish(call, transcript = "AI: bye") = CallLifecycle.finish(external_call_id: call.external_call_id, transcript: transcript, recording_url: nil)
  def transfer(call, reason = "wants a person") = CallLifecycle.transfer(CallLog.find(call.id), reason)
  def sms_jobs = enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }

  def in_threads(jobs)
    gate = Queue.new
    threads = jobs.map do |job|
      Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          job.call
        end
      end
    end
    jobs.size.times { gate << :go }
    Timeout.timeout(30) { threads.map(&:value) }
  end

  test "tool vs finish (submit): either the order is confirmed and the call completed, or both are abandoned and the submit refused" do
    16.times do
      call = new_call
      tool(call, "add", "add_to_cart", { "menu_item_id" => @burger.id })
      tool(call, "cart", "get_cart")
      before_sms = sms_jobs

      in_threads([ -> { tool(call, "sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) }, -> { finish(call) } ].shuffle)
      results = call.tool_invocations.find_by!(tool_call_id: "sub").result
      order = call.reload.order
      if JSON.parse(results)["ok"] # the submit took the lock first
        assert_equal [ "confirmed", "completed", before_sms + 1 ], [ order.status, call.status, sms_jobs ]
      else # the finish took the lock first
        assert_equal "no_active_call", JSON.parse(results).dig("error", "code")
        assert_equal [ "abandoned", "abandoned", before_sms ], [ order.status, call.status, sms_jobs ]
        assert_equal 1, order.order_items.count, "items kept"
      end
      assert_predicate call.ended_at, :present?
    end
  end

  test "tool vs finish (first add): the cart either exists and is abandoned, or never comes into being" do
    16.times do
      call = new_call
      in_threads([ -> { tool(call, "add", "add_to_cart", { "menu_item_id" => @burger.id }) }, -> { finish(call) } ].shuffle)
      result = JSON.parse(call.tool_invocations.find_by!(tool_call_id: "add").result)
      order = call.reload.order

      assert_predicate call, :abandoned?
      if result["ok"]
        assert_equal [ "abandoned", 1 ], [ order.status, order.order_items.count ], "applied, then the finish abandoned it"
      else
        assert_equal "no_active_call", result.dig("error", "code")
        assert_nil order
        assert_equal 0, Order.where(customer: call.customer).count
      end
    end
  end

  test "tool vs transfer: both are applied; the call ends up transferred and the order is whatever the tool decided" do
    12.times do
      call = new_call
      tool(call, "add", "add_to_cart", { "menu_item_id" => @burger.id })
      tool(call, "cart", "get_cart")
      in_threads([ -> { tool(call, "sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) },
                   -> { tool(call, "xfer", "transfer_to_human", { "reason" => "question" }) } ].shuffle)

      assert_predicate call.reload, :transferred?
      assert_equal "question", call.transfer_reason
      assert_predicate call.order, :confirmed?
      assert_equal %w[ok ok], call.tool_invocations.where(tool_call_id: %w[sub xfer]).order(:tool_call_id).pluck(:status)
    end
  end

  test "finish vs transfer: transferred always wins, in either order" do
    12.times do
      call = new_call
      tool(call, "add", "add_to_cart", { "menu_item_id" => @burger.id })
      in_threads([ -> { finish(call) }, -> { transfer(call) } ].shuffle)

      assert_predicate call.reload, :transferred?
      assert_equal "wants a person", call.transfer_reason
      assert_predicate call.ended_at, :present?
      assert_predicate call.order, :abandoned?
    end
  end

  test "duplicate finish: one effect however many arrive at once" do
    call = new_call
    tool(call, "add", "add_to_cart", { "menu_item_id" => @burger.id })
    in_threads(Array.new(4) { |i| -> { finish(call, "report #{i}") } })

    call.reload
    assert_match(/\Areport \d\z/, call.transcript)
    assert_equal [ "abandoned", "abandoned", 1 ], [ call.status, call.order.status, call.order.order_items.count ]
    winner = call.transcript
    finish(call, "a much later duplicate")
    assert_equal winner, call.reload.transcript
    assert_equal 0, sms_jobs
  end

  test "duplicate finish after a submit: one SMS in total, the order stays confirmed" do
    call = new_call
    tool(call, "add", "add_to_cart", { "menu_item_id" => @burger.id })
    tool(call, "cart", "get_cart")
    tool(call, "sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 })
    in_threads(Array.new(4) { -> { finish(call) } })

    assert_predicate call.reload.order, :confirmed?
    assert_predicate call, :completed?
    assert_equal 1, sms_jobs
  end

  test "duplicate call-start: concurrent starts of one call id create exactly one call and one customer" do
    6.times do |i|
      id = "dup_start_#{i}"
      results = in_threads(Array.new(4) { -> { CallLifecycle.start(external_call_id: id, dialed_number: @restaurant.phone_number, caller_number: nil) } })

      assert_equal [ 1, 1 ], [ CallLog.where(external_call_id: id).count, Customer.where(phone_number: "unknown-#{id}").count ]
      assert_equal 1, results.compact.size, "exactly one delivery created the call; the rest were absorbed"
    end
  end

  test "concurrent starts of different calls from the same caller share one customer" do
    in_threads(Array.new(4) { |i| -> { CallLifecycle.start(external_call_id: "same_caller_#{i}", dialed_number: @restaurant.phone_number, caller_number: "+15557772222") } })
    assert_equal [ 4, 1 ], [ CallLog.count, Customer.where(phone_number: "+15557772222").count ]
  end

  test "a burst of everything on one call terminates without deadlock and ends in a consistent state" do
    6.times do
      call = new_call
      tool(call, "add", "add_to_cart", { "menu_item_id" => @burger.id })
      tool(call, "cart", "get_cart")
      sms_before = sms_jobs
      jobs = [
        -> { tool(call, "sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) },
        -> { tool(call, "sub", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) },
        -> { tool(call, "add2", "add_to_cart", { "menu_item_id" => @burger.id }) },
        -> { tool(call, "xfer", "transfer_to_human", { "reason" => "r" }) },
        -> { finish(call) }, -> { finish(call) }, -> { transfer(call) },
        -> { tool(call, "menu", "get_menu") }
      ]
      in_threads(jobs.shuffle)

      call.reload
      order = call.order
      assert_predicate call, :transferred?
      assert_predicate call.ended_at, :present?
      assert_includes %w[confirmed abandoned], order.status, "a cart is either submitted or abandoned once the call has ended"
      assert_equal(order.confirmed? ? 1 : 0, sms_jobs - sms_before, "a confirmed order sent exactly one SMS; an abandoned one none")
      assert_equal 1, call.tool_invocations.where(tool_call_id: "sub").count, "the duplicate submit delivery was a replay"
      assert_equal order.order_items.count, order.cart_version, "every applied add has its own version"
    end
  end
end

require "test_helper"
require "timeout"

# Real threads on committed data (transactions off; each thread has its own connection). These exercise the actual
# guarantees of Step 7: one execution per (call, toolCallId), atomic business change + audit row, no deadlocks.
class Voice::ToolRunnerConcurrencyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    @restaurant = Restaurant.create!(name: "Race Bistro", phone_number: "+15550007878", business_hours: ALWAYS_OPEN_HOURS)
    category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @burger = category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @fries = category.menu_items.create!(restaurant: @restaurant, name: "Fries", price_cents: 400)
    @seq = 0
  end

  teardown do
    [ ToolInvocation, CallLog, OrderItem, Order, Customer, MenuItem, MenuCategory, Restaurant ].each(&:delete_all)
  end

  def new_call = CallLifecycle.start(external_call_id: "race_#{@seq += 1}", dialed_number: @restaurant.phone_number, caller_number: "+1555777#{format("%04d", @seq)}")

  def deliver(call, id, name, args = {})
    Voice::ToolRunner.call(call_log: CallLog.find(call.id), tool_call: { "id" => id, "function" => { "name" => name, "arguments" => args } },
                           artifact: VapiHistory.for_tool(name, id)) # submit_order: the caller answered (see VapiHistory)
  end

  # Runs every job on its own thread/connection, released together.
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

  def sms_jobs = enqueued_jobs.count { |j| j["job_class"] == "OrderConfirmationSmsJob" }

  test "simultaneous deliveries of the same add_to_cart execute once and share one stored result" do
    8.times do
      call = new_call
      results = in_threads(Array.new(4) { -> { deliver(call, "same_add", "add_to_cart", { "menu_item_id" => @burger.id }) } })

      assert_equal 1, results.uniq.size, "every delivery returns the one authoritative result"
      assert_equal true, JSON.parse(results.first)["ok"]
      order = call.reload.order
      assert_equal [ 1, 1, 1 ], [ order.order_items.count, order.cart_version, Order.where(id: order.id).count ]
      row = call.tool_invocations.sole
      assert_equal [ 3, [ 0, 1 ], results.first ], [ row.replay_count, [ row.cart_version_before, row.cart_version_after ], row.result ]
    end
    assert_equal 8, Order.count
  end

  test "simultaneous deliveries of the same submit confirm once and enqueue one SMS" do
    call = new_call
    deliver(call, "add", "add_to_cart", { "menu_item_id" => @burger.id })
    deliver(call, "cart", "get_cart")

    results = in_threads(Array.new(4) { -> { deliver(call, "same_submit", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) } })

    assert_equal 1, results.uniq.size
    assert_equal true, JSON.parse(results.first)["ok"]
    assert_predicate call.reload.order, :confirmed?
    assert_equal 1, sms_jobs
    assert_equal 3, call.tool_invocations.find_by!(tool_call_id: "same_submit").replay_count
  end

  test "simultaneous duplicate get_cart deliveries record one read-back" do
    call = new_call
    deliver(call, "add", "add_to_cart", { "menu_item_id" => @burger.id })
    results = in_threads(Array.new(4) { -> { deliver(call, "same_cart", "get_cart") } })

    assert_equal 1, results.uniq.size
    assert_equal 3, call.tool_invocations.find_by!(tool_call_id: "same_cart").replay_count
    assert_equal 1, call.reload.order.read_back_version
  end

  test "different tool calls racing on one call interleave safely: no deadlock, no lost version, one row per id" do
    5.times do
      call = new_call
      deliver(call, "seed", "add_to_cart", { "menu_item_id" => @burger.id })
      deliver(call, "seed_cart", "get_cart")

      jobs = []
      2.times do
        jobs << -> { deliver(call, "add_b", "add_to_cart", { "menu_item_id" => @fries.id }) }
        jobs << -> { deliver(call, "add_c", "add_to_cart", { "menu_item_id" => @fries.id }) }
        jobs << -> { deliver(call, "cart_x", "get_cart") }
        jobs << -> { deliver(call, "sub_x", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }) }
        jobs << -> { deliver(call, "menu_x", "get_menu") }
      end
      results = in_threads(jobs.shuffle)

      assert(results.all? { |r| JSON.parse(r).key?("ok") })
      ids = %w[seed seed_cart add_b add_c cart_x sub_x menu_x]
      assert_equal ids.sort, call.tool_invocations.pluck(:tool_call_id).sort, "exactly one row per tool call id"
      assert_equal 1, call.tool_invocations.where(tool_call_id: %w[add_b add_c cart_x sub_x menu_x]).pluck(:replay_count).uniq.sole

      order = call.reload.order
      adds_applied = call.tool_invocations.where(tool_call_id: %w[add_b add_c], status: "ok").count
      assert_equal 1 + adds_applied, order.cart_version, "every applied mutation has its own version"
      assert_equal 1 + adds_applied, order.order_items.count
      if order.confirmed?
        assert_equal order.cart_version, order.read_back_version, "confirmed only at the version that was read back"
      end
    end
  end

  test "the business change and its ToolInvocation become visible together, never one without the other" do
    call = new_call
    reached = Queue.new
    release = Queue.new
    original = ToolInvocation.method(:record!)
    ToolInvocation.define_singleton_method(:record!) do |**args|
      reached << :business_done_audit_not_yet_written
      release.pop
      original.call(**args)
    end

    begin
      worker = Thread.new do
        Thread.current.report_on_exception = false
        ActiveRecord::Base.connection_pool.with_connection { deliver(call, "atomic", "add_to_cart", { "menu_item_id" => @burger.id }) }
      end
      Timeout.timeout(10) { reached.pop }

      # The worker has inserted the order item but not the audit row, and has not committed: we see neither.
      observer = ActiveRecord::Base.connection_pool.with_connection do
        [ OrderItem.count, Order.count, ToolInvocation.count, call.reload.order_id ]
      end
      assert_equal [ 0, 0, 0, nil ], observer, "nothing is visible before commit"
    ensure
      release << :go
    end
    Timeout.timeout(10) { worker.value }
    ToolInvocation.define_singleton_method(:record!, original)

    assert_equal [ 1, 1, 1 ], [ OrderItem.count, Order.count, ToolInvocation.count ]
    assert_equal "ok", call.tool_invocations.sole.status
  end

  test "a crash between the business change and the audit row leaves neither behind" do
    call = new_call
    original = ToolInvocation.method(:record!)
    ToolInvocation.define_singleton_method(:record!) { |**| raise Interrupt, "process killed" } # not a StandardError: escapes every rescue
    begin
      assert_raises(Interrupt) { deliver(call, "crash", "add_to_cart", { "menu_item_id" => @burger.id }) }
    ensure
      ToolInvocation.define_singleton_method(:record!, original)
    end

    assert_equal [ 0, 0, 0 ], [ OrderItem.count, Order.count, ToolInvocation.count ]
    assert_nil call.reload.order_id
    # the redelivery after the "crash" executes normally, exactly once
    deliver(call, "crash", "add_to_cart", { "menu_item_id" => @burger.id })
    assert_equal [ 1, 1 ], [ call.reload.order.order_items.count, call.tool_invocations.count ]
  end
end

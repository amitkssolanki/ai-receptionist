require "test_helper"

# Real threads on committed data: the call/order row locks must make stale or racing operations safe.
# Transactions are off for this class (each thread needs its own committed view); data is cleaned up by hand.
class OrderTakingConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @restaurant = Restaurant.create!(name: "Race Bistro", phone_number: "+15550003434", business_hours: ALWAYS_OPEN_HOURS)
    @burger = @restaurant.menu_categories.create!(name: "Mains", position: 1)
                         .menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @customer = @restaurant.customers.create!(phone_number: "unknown-race")
  end

  teardown do
    ToolInvocation.delete_all
    CallLog.delete_all
    OrderItem.delete_all
    Order.delete_all
    Customer.delete_all
    MenuItem.delete_all
    MenuCategory.delete_all
    Restaurant.delete_all
  end

  def new_call(id) = @restaurant.call_logs.create!(external_call_id: id, customer: @customer, phone_number: "unknown-race")

  def in_threads(*jobs)
    barrier = Queue.new
    threads = jobs.map do |job|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          job.call
        end
      end
    end
    jobs.size.times { barrier << :go }
    threads.map(&:value)
  end

  test "concurrent adds are all applied and every one gets its own version (no lost updates)" do
    call = new_call("race_adds")
    results = in_threads(*Array.new(4) { -> { OrderTaking.new(CallLog.find(call.id)).add_item(menu_item_id: @burger.id) } })

    assert(results.none?(&:rejected?))
    assert_equal [ 1, 2, 3, 4 ], results.map { |r| r.payload[:cart_version] }.sort
    order = call.reload.order
    assert_equal [ 4, 4, 1 ], [ order.cart_version, order.order_items.count, Order.count ]
    assert_equal 4000, order.total_cents
  end

  test "a submit racing an add never confirms a cart that was not read back" do
    12.times do |i|
      call = new_call("race_submit_#{i}")
      OrderTaking.new(call).add_item(menu_item_id: @burger.id)
      OrderTaking.new(call.reload).read_back

      submit, add = in_threads(
        -> { OrderTaking.new(CallLog.find(call.id)).submit(fulfillment_type: "pickup", cart_version: 1) },
        -> { OrderTaking.new(CallLog.find(call.id)).add_item(menu_item_id: @burger.id) }
      )
      order = call.reload.order

      if order.confirmed?
        assert_not_predicate submit, :rejected?
        assert_equal :order_already_submitted, add.rejection, "the add lost the race and must be refused"
        assert_equal [ 1, 1, 1 ], [ order.cart_version, order.read_back_version, order.order_items.count ]
      else
        assert_equal :cart_changed_since_readback, submit.rejection
        assert_not_predicate add, :rejected?
        assert_equal [ 2, 1, 2 ], [ order.cart_version, order.read_back_version, order.order_items.count ]
      end
    end
  end

  test "two racing submits of the same version: both see consistent state and the order is confirmed once" do
    call = new_call("race_double_submit")
    OrderTaking.new(call).add_item(menu_item_id: @burger.id)
    OrderTaking.new(call.reload).read_back

    results = in_threads(*Array.new(2) { -> { OrderTaking.new(CallLog.find(call.id)).submit(fulfillment_type: "pickup", cart_version: 1) } })

    assert(results.none?(&:rejected?)) # duplicate-submit idempotency is a later step; both calls are consistent today
    order = call.reload.order
    assert_predicate order, :confirmed?
    assert_equal [ 1, 1 ], [ order.cart_version, order.order_items.count ]
  end
end

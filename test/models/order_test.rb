require "test_helper"

class OrderTest < ActiveSupport::TestCase
  setup do
    restaurant = Restaurant.create!(name: "State Bistro", phone_number: "+15550009990")
    @order = restaurant.orders.create!(customer: restaurant.customers.create!(phone_number: "+15551230000"), fulfillment_type: :pickup)
  end

  def move_to(*statuses) = statuses.each { |s| @order.update!(status: s) }

  test "a normal lifecycle walks forward" do
    assert_nothing_raised { move_to(:confirmed, :preparing, :ready, :completed) }
  end

  test "nothing returns to pending" do
    %i[confirmed preparing ready].each do |status|
      @order.update_columns(status: status.to_s)
      assert_not @order.update(status: :pending), "#{status} -> pending"
      assert_match(/can't change from #{status} to pending/, @order.errors[:status].to_sentence)
    end
  end

  test "completed, cancelled and abandoned are final" do
    %i[completed cancelled abandoned].each do |final|
      @order.update_columns(status: final.to_s)
      Order.statuses.keys.without(final.to_s).each do |target|
        assert_not @order.update(status: target), "#{final} -> #{target}"
      end
      assert_empty @order.allowed_next_statuses
    end
  end

  test "pending can be confirmed, cancelled or abandoned, but not jump to the kitchen" do
    assert_equal %w[confirmed cancelled abandoned], @order.allowed_next_statuses
    assert_not @order.update(status: :preparing)
  end

  test "only a pending order has an open cart" do
    assert_predicate @order, :cart_open?
    move_to(:confirmed)
    assert_not_predicate @order, :cart_open?
  end

  test "saving other fields on a final order is not blocked" do
    @order.update_columns(status: "completed")
    assert @order.update(notes: "late note")
  end
end

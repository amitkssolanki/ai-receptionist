require "test_helper"

class Admin::OrdersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @restaurant = Restaurant.create!(name: "Admin Bistro", phone_number: "+15550009991")
    @user = User.create!(email: "owner-orders@example.com", password: "password123", restaurant: @restaurant)
    customer = @restaurant.customers.create!(phone_number: "+15551230001")
    @order = @restaurant.orders.create!(customer: customer, fulfillment_type: :pickup, status: :confirmed)
    sign_in @user
  end

  test "moving an order forward works" do
    patch admin_order_path(@order), params: { order: { status: "preparing" } }
    assert_redirected_to admin_order_path(@order)
    assert_predicate @order.reload, :preparing?
  end

  test "an order cannot be reopened to pending" do
    patch admin_order_path(@order), params: { order: { status: "pending" } }
    assert_redirected_to admin_order_path(@order)
    assert_match(/can't change from confirmed to pending/, flash[:alert])
    assert_predicate @order.reload, :confirmed?
  end

  test "a final order cannot be changed" do
    @order.update!(status: :cancelled)
    patch admin_order_path(@order), params: { order: { status: "confirmed" } }
    assert_match(/can't change from cancelled/, flash[:alert])
    assert_predicate @order.reload, :cancelled?
  end

  test "the status picker offers only the current status and valid next steps" do
    get admin_order_path(@order)
    assert_select "select[name='order[status]'] option", count: 5 # confirmed + preparing, ready, completed, cancelled
    assert_select "select[name='order[status]'] option[value=pending]", count: 0
  end
end

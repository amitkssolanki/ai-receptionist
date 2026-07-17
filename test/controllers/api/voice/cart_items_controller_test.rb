require "test_helper"

class Api::Voice::CartItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["VOICE_WEBHOOK_SECRET"] = "test-secret"

    @restaurant = Restaurant.create!(name: "Test Bistro", phone_number: "+15550002222")
    @category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @menu_item = @category.menu_items.create!(
      restaurant: @restaurant, name: "Burger", price_cents: 1000, position: 1
    )
    @customer = @restaurant.customers.create!(phone_number: "+15559998888")
    @call_log = @restaurant.call_logs.create!(
      customer: @customer, external_call_id: "call_9", phone_number: @customer.phone_number, started_at: Time.current
    )
  end

  teardown do
    ENV.delete("VOICE_WEBHOOK_SECRET")
  end

  def auth_headers
    { "Authorization" => "Bearer test-secret" }
  end

  test "updates quantity and recomputes the order total" do
    post api_voice_call_cart_items_path(@call_log.external_call_id),
      params: { menu_item_id: @menu_item.id, quantity: 1 }, headers: auth_headers
    order_item_id = JSON.parse(response.body)["items"].first["id"]

    patch api_voice_call_cart_item_path(@call_log.external_call_id, order_item_id),
      params: { quantity: 3 }, headers: auth_headers
    assert_response :success
    assert_equal 30.0, JSON.parse(response.body)["total"]
    assert_equal 3000, @call_log.reload.order.total_cents
  end

  test "removing the only item empties the cart" do
    post api_voice_call_cart_items_path(@call_log.external_call_id),
      params: { menu_item_id: @menu_item.id, quantity: 1 }, headers: auth_headers
    order_item_id = JSON.parse(response.body)["items"].first["id"]

    delete api_voice_call_cart_item_path(@call_log.external_call_id, order_item_id), headers: auth_headers
    assert_response :success
    cart = JSON.parse(response.body)
    assert_empty cart["items"]
    assert_equal 0.0, cart["total"]
  end
end

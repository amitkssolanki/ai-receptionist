require "test_helper"

class Api::Voice::CallsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["VOICE_WEBHOOK_SECRET"] = "test-secret"

    @restaurant = Restaurant.create!(name: "Test Bistro", phone_number: "+15550001111")
    @category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @menu_item = @category.menu_items.create!(
      restaurant: @restaurant, name: "Burger", price_cents: 1000, position: 1
    )
    @modifier = @menu_item.menu_item_modifiers.create!(name: "Add cheese", price_cents: 150)
  end

  teardown do
    ENV.delete("VOICE_WEBHOOK_SECRET")
  end

  def auth_headers
    { "Authorization" => "Bearer test-secret" }
  end

  test "rejects requests without the correct webhook secret" do
    post api_voice_calls_path, params: { external_call_id: "x", from: "+1", to: "+1" }
    assert_response :unauthorized
  end

  test "creates a call, fetches menu, builds a cart, and submits the order" do
    post api_voice_calls_path,
      params: { external_call_id: "call_1", from: "+15551234567", to: @restaurant.phone_number },
      headers: auth_headers
    assert_response :created
    assert_equal "Test Bistro", JSON.parse(response.body)["restaurant"]["name"]

    call_log = CallLog.find_by!(external_call_id: "call_1")
    assert_equal @restaurant, call_log.restaurant
    assert_equal "+15551234567", call_log.customer.phone_number

    get menu_api_voice_call_path(call_log.external_call_id), headers: auth_headers
    assert_response :success
    menu = JSON.parse(response.body)
    assert_equal "Burger", menu.dig(0, "items", 0, "name")

    post api_voice_call_cart_items_path(call_log.external_call_id),
      params: { menu_item_id: @menu_item.id, quantity: 2, modifier_ids: [ @modifier.id ] },
      headers: auth_headers
    assert_response :created
    cart = JSON.parse(response.body)
    assert_equal 23.0, cart["total"]

    assert_enqueued_with(job: OrderConfirmationSmsJob) do
      post submit_api_voice_call_path(call_log.external_call_id),
        params: { fulfillment_type: "pickup" },
        headers: auth_headers
    end
    assert_response :success

    call_log.reload
    assert call_log.order.confirmed?
    assert_equal 2300, call_log.order.total_cents
  end

  test "submitting an empty cart is rejected" do
    post api_voice_calls_path,
      params: { external_call_id: "call_2", from: "+15551234567", to: @restaurant.phone_number },
      headers: auth_headers

    post submit_api_voice_call_path("call_2"), params: { fulfillment_type: "pickup" }, headers: auth_headers
    assert_response :unprocessable_entity
  end

  test "transfer marks the call as transferred" do
    post api_voice_calls_path,
      params: { external_call_id: "call_3", from: "+15551234567", to: @restaurant.phone_number },
      headers: auth_headers

    post transfer_api_voice_call_path("call_3"), headers: auth_headers
    assert_response :success
    assert CallLog.find_by!(external_call_id: "call_3").transferred?
  end

  test "end_call records the transcript and marks abandoned when no order was placed" do
    post api_voice_calls_path,
      params: { external_call_id: "call_4", from: "+15551234567", to: @restaurant.phone_number },
      headers: auth_headers

    post end_call_api_voice_call_path("call_4"),
      params: { transcript: "hello...", recording_url: "https://example.com/rec.mp3" },
      headers: auth_headers
    assert_response :success

    call_log = CallLog.find_by!(external_call_id: "call_4")
    assert call_log.abandoned?
    assert_equal "hello...", call_log.transcript
    assert_not_nil call_log.ended_at
  end
end

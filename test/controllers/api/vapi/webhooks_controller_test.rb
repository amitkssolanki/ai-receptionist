require "test_helper"

class Api::Vapi::WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["VAPI_SERVER_SECRET"] = "test-vapi-secret"

    @restaurant = Restaurant.create!(name: "Test Bistro", phone_number: "+15550001111")
    @category = @restaurant.menu_categories.create!(name: "Mains", position: 1)
    @menu_item = @category.menu_items.create!(restaurant: @restaurant, name: "Burger", price_cents: 1000)
    @modifier = @menu_item.menu_item_modifiers.create!(name: "Add cheese", price_cents: 150)
  end

  teardown do
    ENV.delete("VAPI_SERVER_SECRET")
  end

  def headers
    { "X-Vapi-Secret" => "test-vapi-secret" }
  end

  def post_event(message)
    post api_vapi_webhooks_path, params: { message: message }, headers: headers, as: :json
  end

  test "rejects requests without the correct secret" do
    post api_vapi_webhooks_path, params: { message: { type: "status-update", status: "in-progress" } }, as: :json
    assert_response :unauthorized
  end

  test "status-update in-progress creates a call log, resolving the restaurant by dialed number" do
    post_event(
      type: "status-update",
      status: "in-progress",
      call: { id: "vapi_call_1", phoneNumber: { number: @restaurant.phone_number }, customer: { number: "+15559998888" } }
    )
    assert_response :success

    call_log = CallLog.find_by!(external_call_id: "vapi_call_1")
    assert_equal @restaurant, call_log.restaurant
    assert_equal "+15559998888", call_log.customer.phone_number
  end

  test "status-update falls back to the only restaurant when the dialed number doesn't match" do
    post_event(
      type: "status-update",
      status: "in-progress",
      call: { id: "vapi_call_2", phoneNumber: { number: "+19998887777" }, customer: { number: "+15559998888" } }
    )
    assert_response :success
    assert_equal @restaurant, CallLog.find_by!(external_call_id: "vapi_call_2").restaurant
  end

  test "get_menu tool call returns the restaurant's menu wrapped in Vapi's results shape" do
    post_event(
      type: "status-update", status: "in-progress",
      call: { id: "vapi_call_3", phoneNumber: { number: @restaurant.phone_number }, customer: { number: "+15551112222" } }
    )

    post_event(
      type: "tool-calls",
      call: { id: "vapi_call_3" },
      toolCallList: [ { id: "toolu_1", function: { name: "get_menu", arguments: {} } } ]
    )
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal "toolu_1", body["results"].first["toolCallId"]
    menu = JSON.parse(body["results"].first["result"])
    assert_equal "Burger", menu.dig(0, "items", 0, "name")
  end

  test "add_to_cart then submit_order builds and confirms an order" do
    post_event(
      type: "status-update", status: "in-progress",
      call: { id: "vapi_call_4", phoneNumber: { number: @restaurant.phone_number }, customer: { number: "+15551112222" } }
    )

    post_event(
      type: "tool-calls",
      call: { id: "vapi_call_4" },
      toolCallList: [ {
        id: "toolu_2",
        function: { name: "add_to_cart", arguments: { menu_item_id: @menu_item.id, quantity: 2, modifier_ids: [ @modifier.id ] } }
      } ]
    )
    assert_response :success
    cart = JSON.parse(JSON.parse(response.body)["results"].first["result"])
    assert_equal 23.0, cart["total"]

    assert_enqueued_with(job: OrderConfirmationSmsJob) do
      post_event(
        type: "tool-calls",
        call: { id: "vapi_call_4" },
        toolCallList: [ { id: "toolu_3", function: { name: "submit_order", arguments: { fulfillment_type: "pickup" } } } ]
      )
    end
    assert_response :success

    call_log = CallLog.find_by!(external_call_id: "vapi_call_4")
    assert call_log.order.confirmed?
    assert_equal 2300, call_log.order.total_cents
  end

  test "end-of-call-report records the transcript and recording" do
    post_event(
      type: "status-update", status: "in-progress",
      call: { id: "vapi_call_5", phoneNumber: { number: @restaurant.phone_number }, customer: { number: "+15551112222" } }
    )

    post_event(
      type: "end-of-call-report",
      call: { id: "vapi_call_5" },
      artifact: { transcript: "AI: hi\nCustomer: bye", recording: { stereoUrl: "https://example.com/rec.mp3" } }
    )
    assert_response :success

    call_log = CallLog.find_by!(external_call_id: "vapi_call_5")
    assert_equal "AI: hi\nCustomer: bye", call_log.transcript
    assert_equal "https://example.com/rec.mp3", call_log.recording_url
    assert call_log.abandoned?
  end
end

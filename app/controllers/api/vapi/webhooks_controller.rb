# Vapi sends every call event (status changes, tool calls, end-of-call report) to a
# single server URL, rather than templating a call id into per-tool URLs the way our
# generic api/voice/* endpoints assume. This controller is the adapter: it translates
# Vapi's request/response shapes into calls against the same underlying models the
# generic controllers use, so there's one source of truth for the actual business logic.
#
# Some field paths below (the caller/dialed phone number location within the payload)
# are a best effort based on Vapi's docs, which don't fully spell out the Call object
# schema. Verify against a real payload (see the logger.info dump below, or the ngrok
# inspector at http://localhost:4040) the first time a call comes through, and adjust
# the extraction in resolve_restaurant/resolve_caller_number if the fields differ.
class Api::Vapi::WebhooksController < ActionController::API
  before_action :authenticate_vapi!

  def create
    message = params.require(:message).to_unsafe_h
    Rails.logger.info("[Vapi] event: #{message['type']} #{message.except('artifact').to_json}")

    case message["type"]
    when "status-update"
      handle_status_update(message) if message["status"] == "in-progress"
      head :ok
    when "tool-calls"
      handle_tool_calls(message)
    when "end-of-call-report"
      handle_end_of_call(message)
      head :ok
    else
      # Unhandled event types (transcript, speech-update, etc.) are just acknowledged.
      head :ok
    end
  end

  private

  def authenticate_vapi!
    provided = request.headers["X-Vapi-Secret"].to_s
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, expected_secret)
  end

  def expected_secret
    ENV["VAPI_SERVER_SECRET"].presence || (Rails.env.production? ? SecureRandom.hex : "dev-secret-change-me")
  end

  # --- Call lifecycle ---

  def handle_status_update(message)
    call = message["call"] || {}
    external_call_id = call["id"]
    return if external_call_id.blank? || CallLog.exists?(external_call_id: external_call_id)

    restaurant = resolve_restaurant(message, call)
    unless restaurant
      Rails.logger.warn("[Vapi] Could not resolve a restaurant for call #{external_call_id} - check the dialed-number field path")
      return
    end

    caller_number = resolve_caller_number(message, call) || "unknown-#{external_call_id}"
    customer = restaurant.customers.find_or_create_by!(phone_number: caller_number)

    restaurant.call_logs.create!(
      external_call_id: external_call_id,
      customer: customer,
      phone_number: caller_number,
      started_at: Time.current
    )
  end

  def handle_end_of_call(message)
    call_log = CallLog.find_by(external_call_id: message.dig("call", "id"))
    return unless call_log

    artifact = message["artifact"] || {}
    call_log.update!(
      status: call_log.order&.confirmed? ? "completed" : "abandoned",
      transcript: artifact["transcript"],
      recording_url: artifact.dig("recording", "stereoUrl") || artifact.dig("recording", "url"),
      ended_at: Time.current
    )
  end

  # Single restaurant pilot: fall back to the only restaurant in the system if the
  # dialed-number lookup comes up empty, so an unexpected field name doesn't hard-fail.
  def resolve_restaurant(message, call)
    dialed_number = call.dig("phoneNumber", "number") || message.dig("phoneNumber", "number")
    Restaurant.find_by(phone_number: dialed_number) || (Restaurant.count == 1 ? Restaurant.first : nil)
  end

  def resolve_caller_number(message, call)
    message.dig("customer", "number") || call.dig("customer", "number")
  end

  # --- Tool calls ---

  def handle_tool_calls(message)
    call_log = CallLog.find_by(external_call_id: message.dig("call", "id"))
    tool_calls = message["toolCallList"] || []

    results = tool_calls.map do |tool_call|
      { toolCallId: tool_call["id"], result: dispatch_tool(call_log, tool_call) }
    end

    render json: { results: results }
  end

  def dispatch_tool(call_log, tool_call)
    return "No active call found for this request." unless call_log

    name = tool_call.dig("function", "name") || tool_call["name"]
    arguments = tool_call.dig("function", "arguments") || tool_call["arguments"] || {}
    arguments = JSON.parse(arguments) if arguments.is_a?(String)

    case name
    when "get_menu" then call_log.restaurant.voice_menu_json.to_json
    when "add_to_cart" then add_to_cart(call_log, arguments).to_json
    when "update_cart_item_quantity" then update_cart_item_quantity(call_log, arguments).to_json
    when "remove_cart_item" then remove_cart_item(call_log, arguments).to_json
    when "get_cart" then (call_log.order&.cart_summary || { items: [], total: 0.0 }).to_json
    when "submit_order" then submit_order(call_log, arguments).to_json
    when "transfer_to_human" then transfer_to_human(call_log, arguments)
    else "Unknown tool: #{name}"
    end
  rescue => e
    Rails.logger.error("[Vapi] tool #{name} failed: #{e.class}: #{e.message}")
    "Sorry, something went wrong handling that - #{e.message}"
  end

  def add_to_cart(call_log, arguments)
    menu_item = call_log.restaurant.menu_items.available.find(arguments.fetch("menu_item_id"))
    modifiers = menu_item.menu_item_modifiers.where(id: arguments["modifier_ids"] || [])
    order = call_log.order || begin
      new_order = call_log.restaurant.orders.create!(customer: call_log.customer, fulfillment_type: :pickup, total_cents: 0)
      call_log.update!(order: new_order)
      new_order
    end

    order.order_items.create!(
      menu_item: menu_item,
      quantity: arguments["quantity"].presence || 1,
      unit_price_cents: menu_item.price_cents + modifiers.sum(:price_cents),
      selected_modifiers: modifiers.map { |m| { "name" => m.name, "price_cents" => m.price_cents } },
      notes: arguments["notes"]
    )
    order.recompute_total!
    order.cart_summary
  end

  def update_cart_item_quantity(call_log, arguments)
    order = call_log.order
    order_item = order.order_items.find(arguments.fetch("order_item_id"))
    order_item.update!(quantity: arguments.fetch("quantity"))
    order.recompute_total!
    order.cart_summary
  end

  def remove_cart_item(call_log, arguments)
    order = call_log.order
    order.order_items.find(arguments.fetch("order_item_id")).destroy
    order.recompute_total!
    order.cart_summary
  end

  def submit_order(call_log, arguments)
    order = call_log.order
    return { error: "Cart is empty" } if order.nil? || order.order_items.none?

    order.update!(
      fulfillment_type: arguments.fetch("fulfillment_type"),
      delivery_address: arguments["delivery_address"],
      notes: arguments["notes"],
      status: :confirmed,
      placed_at: Time.current
    )
    order.recompute_total!
    OrderConfirmationSmsJob.perform_later(order.id)
    order.cart_summary
  end

  def transfer_to_human(call_log, arguments)
    note = "[Transferred to human#{": #{arguments['reason']}" if arguments["reason"].present?}]"
    call_log.update!(status: :transferred, transcript: [ call_log.transcript, note ].compact.join("\n"))
    "Transfer logged."
  end
end

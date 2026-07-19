class Api::Voice::CallsController < Api::Voice::BaseController
  before_action :set_call_log, except: [ :create ]

  # POST /api/voice/calls
  # Called when the voice platform picks up an inbound call.
  def create
    restaurant = Restaurant.find_by!(phone_number: params.require(:to))
    customer = restaurant.customers.find_or_create_by!(phone_number: params.require(:from))

    call_log = restaurant.call_logs.create!(
      external_call_id: params.require(:external_call_id),
      customer: customer,
      phone_number: params[:from],
      started_at: Time.current
    )

    render json: {
      call_id: call_log.external_call_id,
      restaurant: {
        name: restaurant.name,
        timezone: restaurant.timezone,
        business_hours: restaurant.business_hours,
        open_now: restaurant.open_now?,
        hours_today: restaurant.hours_today
      }
    }, status: :created
  end

  # GET /api/voice/calls/:external_call_id/menu
  def menu
    categories = @call_log.restaurant.menu_categories.includes(menu_items: [ :menu_item_modifiers, :upsell_items ])

    render json: categories.map { |category|
      {
        category: category.name,
        items: category.menu_items.available.map { |item|
          {
            id: item.id,
            name: item.name,
            description: item.description,
            price: item.price,
            modifiers: item.menu_item_modifiers.map { |m| { id: m.id, name: m.name, price: m.price_cents / 100.0 } },
            suggest_with: item.upsell_items.available.map { |u| { id: u.id, name: u.name, price: u.price } }
          }
        }
      }
    }
  end

  # GET /api/voice/calls/:external_call_id/cart
  def cart
    render json: @call_log.order&.cart_summary || { items: [], total: 0.0 }
  end

  # POST /api/voice/calls/:external_call_id/submit
  def submit
    order = @call_log.order

    if order.nil? || order.order_items.none?
      return render json: { error: "Cart is empty" }, status: :unprocessable_entity
    end

    order.update!(
      fulfillment_type: params.require(:fulfillment_type),
      delivery_address: params[:delivery_address],
      notes: params[:notes],
      status: :confirmed,
      placed_at: Time.current
    )
    order.recompute_total!

    OrderConfirmationSmsJob.perform_later(order.id)

    render json: order.cart_summary
  end

  # POST /api/voice/calls/:external_call_id/transfer
  def transfer
    note = "[Transferred to human#{": #{params[:reason]}" if params[:reason].present?}]"
    @call_log.update!(status: :transferred, transcript: [ @call_log.transcript, note ].compact.join("\n"))
    head :ok
  end

  # POST /api/voice/calls/:external_call_id/end_call
  def end_call
    @call_log.update!(
      status: params[:status].presence || (@call_log.order&.confirmed? ? "completed" : "abandoned"),
      transcript: params[:transcript],
      recording_url: params[:recording_url],
      ended_at: Time.current
    )
    head :ok
  end

  private

  def set_call_log
    @call_log = CallLog.find_by!(external_call_id: params[:external_call_id])
  end
end

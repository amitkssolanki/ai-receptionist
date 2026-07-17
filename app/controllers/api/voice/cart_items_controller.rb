class Api::Voice::CartItemsController < Api::Voice::BaseController
  before_action :set_call_log
  before_action :set_order_item, only: [ :update, :destroy ]

  # POST /api/voice/calls/:external_call_id/cart_items
  def create
    menu_item = @call_log.restaurant.menu_items.available.find(params.require(:menu_item_id))
    modifiers = menu_item.menu_item_modifiers.where(id: params[:modifier_ids] || [])
    order = @call_log.order || create_pending_order!

    order.order_items.create!(
      menu_item: menu_item,
      quantity: params[:quantity].presence || 1,
      unit_price_cents: menu_item.price_cents + modifiers.sum(:price_cents),
      selected_modifiers: modifiers.map { |m| { "name" => m.name, "price_cents" => m.price_cents } },
      notes: params[:notes]
    )
    order.recompute_total!

    render json: order.cart_summary, status: :created
  end

  # PATCH /api/voice/calls/:external_call_id/cart_items/:id
  def update
    @order_item.update!(quantity: params.require(:quantity))
    @order_item.order.recompute_total!

    render json: @order_item.order.cart_summary
  end

  # DELETE /api/voice/calls/:external_call_id/cart_items/:id
  def destroy
    order = @order_item.order
    @order_item.destroy
    order.recompute_total!

    render json: order.cart_summary
  end

  private

  def set_call_log
    @call_log = CallLog.find_by!(external_call_id: params[:call_external_call_id])
  end

  def set_order_item
    @order_item = @call_log.order.order_items.find(params[:id])
  end

  def create_pending_order!
    order = @call_log.restaurant.orders.create!(
      customer: @call_log.customer,
      fulfillment_type: :pickup,
      total_cents: 0
    )
    @call_log.update!(order: order)
    order
  end
end

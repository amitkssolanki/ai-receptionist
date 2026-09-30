# The cart and order rules for one call. Every voice adapter goes through this; none of them may re-implement it.
#
# Inputs are already typed (see Voice::ToolArguments). Anything the server refuses comes back as a rejected
# Result with a code and a speakable message; nothing here leaks exception text.
class OrderTaking
  # payload: what the tool reports on success. rejection/message: a code symbol and guidance for the model.
  Result = Data.define(:payload, :rejection, :message) do
    def self.ok(payload) = new(payload: payload, rejection: nil, message: nil)
    def self.rejected(code, message) = new(payload: nil, rejection: code, message: message)
    def rejected? = !rejection.nil?
  end

  MESSAGES = {
    menu_item_unavailable: "That item isn't on the menu right now. Call get_menu to see what can be ordered, then offer the caller an alternative.",
    item_not_in_cart: "That item isn't in the cart. Call get_cart to see the current items and their ids.",
    cart_empty: "The cart is empty. Add at least one item first.",
    delivery_address_required: "Delivery needs an address. Ask the caller for it, then submit the order again."
  }.freeze

  def initialize(call_log)
    @call_log = call_log
  end

  def cart
    Result.ok(order&.cart_summary || { items: [], total: 0.0 })
  end

  def add_item(menu_item_id:, quantity: nil, modifier_ids: [], notes: nil)
    menu_item = @call_log.restaurant.menu_items.available.find_by(id: menu_item_id)
    return refuse(:menu_item_unavailable) unless menu_item

    modifiers = menu_item.menu_item_modifiers.where(id: modifier_ids)
    cart_order = order || open_order

    cart_order.order_items.create!(
      menu_item: menu_item,
      quantity: quantity || 1,
      unit_price_cents: menu_item.price_cents + modifiers.sum(:price_cents),
      selected_modifiers: modifiers.map { |m| { "name" => m.name, "price_cents" => m.price_cents } },
      notes: notes
    )
    cart_order.recompute_total!
    Result.ok(cart_order.cart_summary)
  end

  def update_quantity(order_item_id:, quantity:)
    return refuse(:cart_empty) unless order

    order_item = order.order_items.find_by(id: order_item_id)
    return refuse(:item_not_in_cart) unless order_item

    order_item.update!(quantity: quantity)
    order.recompute_total!
    Result.ok(order.cart_summary)
  end

  def remove_item(order_item_id:)
    return refuse(:cart_empty) unless order

    order_item = order.order_items.find_by(id: order_item_id)
    return refuse(:item_not_in_cart) unless order_item

    order_item.destroy
    order.recompute_total!
    Result.ok(order.cart_summary)
  end

  def submit(fulfillment_type:, delivery_address: nil, notes: nil)
    cart_order = order
    return refuse(:cart_empty) if cart_order.nil? || cart_order.order_items.none?
    return refuse(:delivery_address_required) if fulfillment_type == "delivery" && delivery_address.blank?

    cart_order.update!(
      fulfillment_type: fulfillment_type,
      delivery_address: delivery_address,
      notes: notes,
      status: :confirmed,
      placed_at: Time.current
    )
    cart_order.recompute_total!
    OrderConfirmationSmsJob.perform_later(cart_order.id)
    Result.ok(cart_order.cart_summary)
  end

  private

  def refuse(code) = Result.rejected(code, MESSAGES.fetch(code))

  def order
    @call_log.order
  end

  def open_order
    new_order = @call_log.restaurant.orders.create!(customer: @call_log.customer, fulfillment_type: :pickup, total_cents: 0)
    @call_log.update!(order: new_order)
    new_order
  end
end

# The cart and order rules for one call. Every voice adapter goes through this; none of them may re-implement it.
#
# Step 2 is a pure extraction of the behavior the Vapi webhook already had: methods take the parsed tool-argument
# hash (string keys) and raise the same exceptions for bad input as before. Typed arguments, rejection codes and
# the real rules arrive in Steps 3-8.
class OrderTaking
  # payload: what the tool reports. rejection: nil, or a code symbol when the request was refused without raising.
  Result = Data.define(:payload, :rejection) do
    def self.ok(payload) = new(payload: payload, rejection: nil)
    def self.rejected(code, payload) = new(payload: payload, rejection: code)
    def rejected? = !rejection.nil?
  end

  def initialize(call_log)
    @call_log = call_log
  end

  def cart
    Result.ok(order&.cart_summary || { items: [], total: 0.0 })
  end

  def add_item(arguments)
    menu_item = @call_log.restaurant.menu_items.available.find(arguments.fetch("menu_item_id"))
    modifiers = menu_item.menu_item_modifiers.where(id: arguments["modifier_ids"] || [])
    cart_order = order || open_order

    cart_order.order_items.create!(
      menu_item: menu_item,
      quantity: arguments["quantity"].presence || 1,
      unit_price_cents: menu_item.price_cents + modifiers.sum(:price_cents),
      selected_modifiers: modifiers.map { |m| { "name" => m.name, "price_cents" => m.price_cents } },
      notes: arguments["notes"]
    )
    cart_order.recompute_total!
    Result.ok(cart_order.cart_summary)
  end

  def update_quantity(arguments)
    cart_order = order
    order_item = cart_order.order_items.find(arguments.fetch("order_item_id"))
    order_item.update!(quantity: arguments.fetch("quantity"))
    cart_order.recompute_total!
    Result.ok(cart_order.cart_summary)
  end

  def remove_item(arguments)
    cart_order = order
    cart_order.order_items.find(arguments.fetch("order_item_id")).destroy
    cart_order.recompute_total!
    Result.ok(cart_order.cart_summary)
  end

  def submit(arguments)
    cart_order = order
    return Result.rejected(:cart_empty, { error: "Cart is empty" }) if cart_order.nil? || cart_order.order_items.none?

    cart_order.update!(
      fulfillment_type: arguments.fetch("fulfillment_type"),
      delivery_address: arguments["delivery_address"],
      notes: arguments["notes"],
      status: :confirmed,
      placed_at: Time.current
    )
    cart_order.recompute_total!
    OrderConfirmationSmsJob.perform_later(cart_order.id)
    Result.ok(cart_order.cart_summary)
  end

  private

  def order
    @call_log.order
  end

  def open_order
    new_order = @call_log.restaurant.orders.create!(customer: @call_log.customer, fulfillment_type: :pickup, total_cents: 0)
    @call_log.update!(order: new_order)
    new_order
  end
end

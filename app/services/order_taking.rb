# The cart and order rules for one call. Every voice adapter goes through this; none of them may re-implement it.
#
# Inputs are already typed (see Voice::ToolArguments). Anything the server refuses comes back as a rejected
# Result with a code and a speakable message; nothing here leaks exception text.
class OrderTaking
  # payload: what the tool reports on success. rejection/message/details: a code symbol, guidance for the model,
  # and any structured facts the model needs to recover (e.g. the current cart_version).
  Result = Data.define(:payload, :rejection, :message, :details) do
    def self.ok(payload) = new(payload: payload, rejection: nil, message: nil, details: {})
    def self.rejected(code, message, details = {}) = new(payload: nil, rejection: code, message: message, details: details)
    def rejected? = !rejection.nil?
  end

  MAX_LINE_QUANTITY = 20
  MAX_ORDER_ITEMS = 30

  MESSAGES = {
    menu_item_unavailable: "That item isn't on the menu right now. Call get_menu to see what can be ordered, then offer the caller an alternative.",
    item_not_in_cart: "That item isn't in the cart. Call get_cart to see the current items and their ids.",
    cart_empty: "The cart is empty. Add at least one item first.",
    delivery_address_required: "Delivery needs an address. Ask the caller for it, then submit the order again.",
    order_already_submitted: "This order has already been submitted and can no longer be changed. Offer to transfer the caller to a person if they need changes.",
    quantity_out_of_range: "Quantity must be a whole number from 1 to #{MAX_LINE_QUANTITY}. For bigger quantities, offer to transfer the caller to staff.",
    large_order_requires_staff: "That would take the order past #{MAX_ORDER_ITEMS} items, which staff need to handle. Offer to transfer the caller to a person.",
    readback_required: "The order hasn't been read back yet. Call get_cart, read its readback_text to the caller exactly as written, " \
                       "get a clear yes, then call submit_order with the cart_version from get_cart."
  }.freeze

  def initialize(call_log)
    @call_log = call_log
  end

  # The server-generated read-back. Records which cart version was read so submit_order can insist on it.
  def read_back
    mutating do
      cart_order = order
      next Result.ok(empty_cart) unless cart_order

      if cart_order.cart_open? && cart_order.order_items.any?
        cart_order.update!(read_back_version: cart_order.cart_version, read_back_at: Time.current)
      end
      Result.ok(cart_order.cart_summary.merge(readback_text: Readback.cart(cart_order)))
    end
  end

  def add_item(menu_item_id:, quantity: nil, modifier_ids: [], notes: nil)
    mutating do
      quantity ||= 1
      next refuse(:restaurant_closed, closed_message) unless restaurant.open_now?
      next refuse(:order_already_submitted) if order && !order.cart_open?

      menu_item = restaurant.menu_items.available.find_by(id: menu_item_id)
      next refuse(:menu_item_unavailable) unless menu_item
      next refuse(:quantity_out_of_range) unless quantity.between?(1, MAX_LINE_QUANTITY)

      modifiers = menu_item.menu_item_modifiers.where(id: modifier_ids.uniq).to_a
      unknown = modifier_ids.uniq - modifiers.map(&:id)
      next refuse(:invalid_modifier, invalid_modifier_message(menu_item, unknown)) if unknown.any?
      next refuse(:large_order_requires_staff) if item_count + quantity > MAX_ORDER_ITEMS

      cart_order = order || open_order
      added = cart_order.order_items.create!(
        menu_item: menu_item,
        quantity: quantity,
        unit_price_cents: menu_item.price_cents + modifiers.sum(&:price_cents),
        selected_modifiers: modifiers.map { |m| { "name" => m.name, "price_cents" => m.price_cents } },
        notes: notes
      )
      cart_order.recompute_total!(bump_version: true)
      Result.ok(cart_order.cart_summary.merge(confirmation_text: Readback.added(added, cart_order)))
    end
  end

  def update_quantity(order_item_id:, quantity:)
    mutating do
      next refuse(:cart_empty) unless order
      next refuse(:order_already_submitted) unless order.cart_open?

      order_item = order.order_items.find_by(id: order_item_id)
      next refuse(:item_not_in_cart) unless order_item
      next refuse(:quantity_out_of_range) unless quantity.between?(1, MAX_LINE_QUANTITY)
      next refuse(:large_order_requires_staff) if item_count - order_item.quantity + quantity > MAX_ORDER_ITEMS

      order_item.update!(quantity: quantity)
      order.recompute_total!(bump_version: true)
      Result.ok(order.cart_summary.merge(confirmation_text: Readback.changed(order_item, order)))
    end
  end

  def remove_item(order_item_id:)
    mutating do
      next refuse(:cart_empty) unless order
      next refuse(:order_already_submitted) unless order.cart_open?

      order_item = order.order_items.find_by(id: order_item_id)
      next refuse(:item_not_in_cart) unless order_item

      order_item.destroy!
      order.recompute_total!(bump_version: true)
      Result.ok(order.cart_summary.merge(confirmation_text: Readback.removed(order_item.menu_item.name, order)))
    end
  end

  # Submitting requires the cart_version the caller heard read back: the server's current version must equal both
  # the argument and the last read-back. Until the duplicate-submit work, re-submitting a confirmed order still
  # behaves as it always has; orders the kitchen has already picked up (or that ended) are refused.
  def submit(fulfillment_type:, cart_version:, delivery_address: nil, notes: nil)
    mutating do
      cart_order = order
      next refuse(:restaurant_closed, closed_message) unless restaurant.open_now?
      next refuse(:cart_empty) if cart_order.nil? || cart_order.order_items.none?
      next refuse(:order_already_submitted) unless cart_order.cart_open? || cart_order.confirmed?
      next refuse(:delivery_address_required) if fulfillment_type == "delivery" && delivery_address.blank?
      next refuse(:readback_required) if cart_order.read_back_version.nil?
      if cart_version != cart_order.cart_version || cart_order.read_back_version != cart_order.cart_version
        next refuse(:cart_changed_since_readback, changed_since_readback_message(cart_order), cart_version: cart_order.cart_version)
      end

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
  end

  private

  def refuse(code, message = MESSAGES.fetch(code), details = {}) = Result.rejected(code, message, details)

  def empty_cart = { items: [], total: 0.0, cart_version: 0, readback_text: Readback.cart(nil) }

  def changed_since_readback_message(cart_order)
    "The cart has changed since it was last read back; the current cart_version is #{cart_order.cart_version}. " \
      "Call get_cart, read the new readback_text to the caller exactly as written, get a clear yes, " \
      "then call submit_order with cart_version #{cart_order.cart_version}."
  end

  # One transaction per mutation, serialized per call: lock the call row (which also covers creating the order)
  # and the order row. Any exception rolls the whole mutation back - no empty orders, no half-written carts.
  def mutating(&block)
    @call_log.with_lock do
      order&.lock!
      block.call
    end
  end

  def restaurant = @call_log.restaurant

  def item_count = order ? order.order_items.sum(:quantity) : 0

  def closed_message
    hours = restaurant.hours_today
    today = hours.blank? || hours == "closed" ? "closed today" : "today's hours: #{hours}"
    "The restaurant is closed right now (#{today}). Tell the caller we can't take an order at the moment and offer to transfer them or suggest calling back when we're open."
  end

  def invalid_modifier_message(menu_item, unknown_ids)
    valid = menu_item.menu_item_modifiers.map(&:name)
    options = valid.any? ? "The options for #{menu_item.name} are: #{valid.to_sentence}." : "#{menu_item.name} has no modifiers."
    "Modifier id#{'s' if unknown_ids.size > 1} #{unknown_ids.to_sentence} #{unknown_ids.size > 1 ? "aren't" : "isn't"} available for #{menu_item.name}. " \
      "#{options} Ask the caller which they want, then add the item again using ids from get_menu."
  end

  def order
    @call_log.order
  end

  def open_order
    new_order = @call_log.restaurant.orders.create!(customer: @call_log.customer, fulfillment_type: :pickup, total_cents: 0)
    @call_log.update!(order: new_order)
    new_order
  end
end

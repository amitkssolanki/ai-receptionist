module ConsoleView
  # The order board: what the server actually holds for this call. Lines, totals, cart version, read-back state,
  # confirmation state and the SMS outcome all come from Order / OrderItem / ToolInvocation rows.
  class Board
    Line = Data.define(:quantity, :name, :modifiers, :subtotal)

    attr_reader :call_log, :order

    def initialize(call_log)
      @call_log = call_log
      @order = call_log.order
    end

    def present? = order.present?
    def restaurant = call_log.restaurant

    def order_id = order&.id

    STATUS_LABELS = { "pending" => "CART OPEN", "confirmed" => "CONFIRMED", "preparing" => "PREPARING", "ready" => "READY",
                      "completed" => "COMPLETED", "cancelled" => "CANCELLED", "abandoned" => "ABANDONED" }.freeze

    def status = order&.status
    def status_label = STATUS_LABELS.fetch(status.to_s, "NO CART YET")
    def locked? = order.present? && !order.cart_open?

    def fulfillment
      return unless order&.fulfillment_type

      order.delivery? ? "delivery (address on file)" : "pickup"
    end

    def lines
      return [] unless order

      order.order_items.includes(:menu_item).order(:id).map do |item|
        Line.new(item.quantity, item.menu_item.name,
                 item.selected_modifiers.map { |m| { name: m["name"], price: m["price_cents"].to_i / 100.0 } },
                 item.subtotal_cents / 100.0)
      end
    end

    def total = order ? order.total_cents / 100.0 : 0.0
    def cart_version = order&.cart_version || 0

    def read_back
      return "not delivered" unless order&.read_back_version

      at = ConsoleView.clock(order.read_back_at, restaurant)
      if order.read_back_version == order.cart_version
        "delivered for v#{order.read_back_version}#{" at #{at}" if at}"
      else
        "STALE: cart v#{order.cart_version}, read-back v#{order.read_back_version}"
      end
    end

    def read_back_stale? = order&.read_back_version.present? && order.read_back_version != order.cart_version

    def confirmation
      return "no cart yet" unless order
      return "abandoned: never submitted" if order.abandoned?
      return "cancelled" if order.cancelled?

      if order.cart_open?
        return "awaiting items" if order.order_items.none?

        order.read_back_version == order.cart_version ? "ready to submit (needs v#{order.cart_version})" : "awaiting read-back"
      else
        [ "submitted v#{order.cart_version}", (" at #{ConsoleView.clock(order.placed_at, restaurant)}" if order.placed_at), duplicates_note ].compact.join
      end
    end

    # The first submit that actually confirmed the order says what happened to the SMS; later submits only replay.
    SMS_LABELS = { "queued" => "confirmation text queued", "skipped_web_call" => "not sent: web call, no phone number" }.freeze

    def sms
      return "n/a" unless order&.submitted?

      sms = submit_invocations.filter_map { |row| JSON.parse(row.result)["confirmation_sms"] rescue nil }.find { |v| SMS_LABELS.key?(v) }
      SMS_LABELS.fetch(sms, "not recorded")
    end

    private

    def submit_invocations = call_log.tool_invocations.where(tool_name: "submit_order", status: "ok").order(:id)

    def duplicates_note
      absorbed = call_log.tool_invocations.where(tool_name: "submit_order").sum(:replay_count) +
                 submit_invocations.count { |row| JSON.parse(row.result)["already_submitted"] rescue false }
      " · duplicate submit absorbed ×#{absorbed}" if absorbed.positive?
    end
  end
end

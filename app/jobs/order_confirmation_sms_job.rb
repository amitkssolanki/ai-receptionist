class OrderConfirmationSmsJob < ApplicationJob
  queue_as :default

  # Enqueues the confirmation once the surrounding transaction has committed (immediately if there is none).
  # Enqueueing is best effort by design: if the queue is unavailable the error is logged (class and order id only)
  # and swallowed, because a confirmed order must never be undone or hidden by an SMS problem. A process crash
  # between COMMIT and the enqueue loses the SMS; that window is a documented limitation, not handled here.
  def self.enqueue_after_commit(order)
    order_id = order.id
    ActiveRecord.after_all_transactions_commit do
      perform_later(order_id)
    rescue => e
      Rails.logger.error("[SMS] could not enqueue confirmation for order #{order_id}: #{e.class}")
    end
  end

  def perform(order_id)
    return unless twilio_configured?

    order = Order.find(order_id)
    unless order.customer.sms_capable?
      Rails.logger.info("[SMS] skipped confirmation for order #{order.id}: caller has no SMS-capable number")
      return
    end

    Twilio::REST::Client.new(twilio_account_sid, twilio_auth_token).messages.create(
      from: twilio_from_number,
      to: order.customer.phone_number,
      body: body_for(order)
    )
  end

  private

  def body_for(order)
    items = order.order_items.includes(:menu_item).map do |item|
      modifiers = item.selected_modifiers.map { |m| m["name"] }
      "#{item.quantity}x #{item.menu_item.name}#{" (#{modifiers.join(', ')})" if modifiers.any?}"
    end
    "Thanks for your order at #{order.restaurant.name}! #{items.join(', ')}. Total: $#{"%.2f" % order.total}. " \
      "We'll have it ready soon."
  end

  def twilio_configured?
    twilio_account_sid.present? && twilio_auth_token.present? && twilio_from_number.present?
  end

  def twilio_account_sid
    ENV["TWILIO_ACCOUNT_SID"]
  end

  def twilio_auth_token
    ENV["TWILIO_AUTH_TOKEN"]
  end

  def twilio_from_number
    ENV["TWILIO_FROM_NUMBER"]
  end
end

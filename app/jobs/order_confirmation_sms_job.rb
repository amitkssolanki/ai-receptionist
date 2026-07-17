class OrderConfirmationSmsJob < ApplicationJob
  queue_as :default

  def perform(order_id)
    return unless twilio_configured?

    order = Order.find(order_id)

    Twilio::REST::Client.new(twilio_account_sid, twilio_auth_token).messages.create(
      from: twilio_from_number,
      to: order.customer.phone_number,
      body: "Thanks for your order at #{order.restaurant.name}! Total: $#{"%.2f" % order.total}. " \
            "We'll have it ready soon."
    )
  end

  private

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

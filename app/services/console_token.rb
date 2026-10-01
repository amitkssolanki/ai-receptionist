# The signed token a browser console call carries to the webhook so the server knows which restaurant (and which
# console page) the call belongs to, without trusting anything the browser or caller says. It is issued only on the
# Devise-protected console page, expires in 15 minutes, and is verified with the app's secret key base. (R23)
module ConsoleToken
  EXPIRY = 15.minutes
  PURPOSE = :vapi_console

  module_function

  def issue(restaurant:, session_key:)
    verifier.generate({ "restaurant_id" => restaurant.id, "session_key" => session_key }, expires_in: EXPIRY, purpose: PURPOSE)
  end

  # Returns { restaurant: Restaurant, session_key: String } or nil for anything forged, expired, tampered with, or pointing
  # at a restaurant that no longer exists.
  def verify(token)
    return if token.blank? || !token.is_a?(String)

    payload = verifier.verified(token, purpose: PURPOSE)
    return unless payload.is_a?(Hash)

    restaurant = Restaurant.find_by(id: payload["restaurant_id"])
    key = payload["session_key"]
    { restaurant: restaurant, session_key: key } if restaurant && key.is_a?(String) && key.match?(/\A[0-9a-f]{16,64}\z/)
  end

  def verifier = Rails.application.message_verifier(:vapi_console)
end

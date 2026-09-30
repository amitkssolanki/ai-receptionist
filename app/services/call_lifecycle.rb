# Call-level state changes: a call starting, being transferred to a human, and ending. Adapters extract the
# provider's fields; what those events mean for our records is decided here.
#
# Status rules (one place, enforced under the call-row lock; lock order is always call_logs -> orders):
#
#   start             -> in_progress            (create-or-find on external_call_id; a duplicate is a no-op)
#   transfer          -> transferred            from ANY status, including after the call ended. transferred outranks
#                                               completed, which outranks abandoned. A second transfer is a no-op
#                                               (the first reason is kept).
#   finish (first)    -> transferred            if the call was transferred
#                     -> completed              else, if an order was submitted (anything past pending, not abandoned)
#                     -> abandoned              else
#                     and an order whose cart is still open becomes abandoned (items kept). A submitted order is
#                     never touched.
#   finish (repeat)   -> no-op. The first end-of-call report wins; nothing is changed, abandoned or notified twice.
#
# Stable identifiers: the call id keys `start` and `finish` (Vapi sends one status-update/in-progress and one
# end-of-call-report per call); transfer arrives as a tool call and is keyed by its toolCallId in ToolInvocation.
# Nothing is keyed by timestamp or payload hash; repeat events are made harmless by the state rules above.
class CallLifecycle
  REASON_LIMIT = 500

  # Returns the new CallLog, or nil when nothing was created (no id, already started, or no restaurant resolved).
  # Two concurrent starts for one call id create exactly one record; the loser sees the winner's and returns nil.
  def self.start(external_call_id:, dialed_number:, caller_number:, console_token: nil)
    return if external_call_id.blank? || CallLog.exists?(external_call_id: external_call_id)

    console = ConsoleToken.verify(console_token)
    restaurant = console&.fetch(:restaurant) || resolve_restaurant(dialed_number)
    unless restaurant
      Rails.logger.warn("[Vapi] Could not resolve a restaurant for call #{external_call_id}: no valid console token, no dialed-number match, no default restaurant")
      return
    end

    caller_number ||= "unknown-#{external_call_id}"
    begin
      CallLog.transaction(requires_new: true) do
        customer = customer_for(restaurant, caller_number)
        restaurant.call_logs.create!(
          external_call_id: external_call_id, customer: customer, phone_number: caller_number, started_at: Time.current,
          console_session_key: console&.fetch(:session_key)
        )
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      raise unless CallLog.find_by(external_call_id: external_call_id) # a duplicate start lost the race; anything else is real

      nil
    end
  end

  # find-or-create that survives two calls creating the same customer at once.
  def self.customer_for(restaurant, phone_number)
    restaurant.customers.find_by(phone_number: phone_number) || begin
      Customer.transaction(requires_new: true) { restaurant.customers.create!(phone_number: phone_number) }
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      restaurant.customers.find_by!(phone_number: phone_number)
    end
  end
  private_class_method :customer_for

  def self.transfer(call_log, reason)
    call_log.with_lock do
      next if call_log.transferred_at

      call_log.update!(status: :transferred, transferred_at: Time.current, transfer_reason: reason.presence&.first(REASON_LIMIT))
    end
  end

  def self.finish(external_call_id:, transcript:, recording_url:, outcome: {})
    call_log = CallLog.find_by(external_call_id: external_call_id)
    return unless call_log

    call_log.with_lock do
      next if call_log.ended_at

      order = call_log.order
      order&.lock!
      call_log.update!(status: final_status(call_log, order), transcript: transcript, recording_url: recording_url, ended_at: Time.current,
                       **outcome_attributes(outcome))
      # A cart still open when the call ends was never submitted: keep its items, but it is no longer a live cart.
      order.update!(status: :abandoned) if order&.cart_open?
    end
  end

  # The report's outcome facts, each optional and defensively typed. Nothing else from the report is kept.
  def self.outcome_attributes(outcome)
    {
      ended_reason: outcome[:ended_reason].to_s.gsub(/[^\w.:\-]/, "").first(64).presence,
      duration_seconds: (Float(outcome[:duration_seconds]).round if outcome[:duration_seconds].present? rescue nil),
      cost_usd: (BigDecimal(outcome[:cost].to_s).round(4) if outcome[:cost].present? rescue nil),
      assistant_version: outcome[:assistant_version].to_s.gsub(/[^\w.\-]/, "").first(32).presence
    }
  end
  private_class_method :outcome_attributes

  def self.final_status(call_log, order)
    return "transferred" if call_log.transferred_at

    order&.submitted? ? "completed" : "abandoned"
  end
  private_class_method :final_status

  # Restaurant resolution (R23), in order: a valid signed console token (handled by the caller), the dialed number,
  # and - only where config.x.vapi.default_restaurant_fallback is on (development and test) - the sole restaurant.
  # Otherwise nothing: the call is refused rather than attached to a guess.
  def self.resolve_restaurant(dialed_number)
    found = Restaurant.find_by(phone_number: dialed_number) if dialed_number.present?
    return found if found

    Restaurant.first if Rails.configuration.x.vapi.default_restaurant_fallback && Restaurant.count == 1
  end
  private_class_method :resolve_restaurant
end

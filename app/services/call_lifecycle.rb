# Call-level state changes: a call starting, being transferred to a human, and ending. Adapters extract the
# provider's fields; what those events mean for our records is decided here.
class CallLifecycle
  # Returns the new CallLog, or nil when nothing was created (no id, already started, or no restaurant resolved).
  def self.start(external_call_id:, dialed_number:, caller_number:)
    return if external_call_id.blank? || CallLog.exists?(external_call_id: external_call_id)

    restaurant = resolve_restaurant(dialed_number)
    unless restaurant
      Rails.logger.warn("[Vapi] Could not resolve a restaurant for call #{external_call_id} - check the dialed-number field path")
      return
    end

    caller_number ||= "unknown-#{external_call_id}"
    customer = restaurant.customers.find_or_create_by!(phone_number: caller_number)

    restaurant.call_logs.create!(
      external_call_id: external_call_id,
      customer: customer,
      phone_number: caller_number,
      started_at: Time.current
    )
  end

  def self.transfer(call_log, reason)
    note = "[Transferred to human#{": #{reason}" if reason.present?}]"
    call_log.update!(status: :transferred, transcript: [ call_log.transcript, note ].compact.join("\n"))
  end

  def self.finish(external_call_id:, transcript:, recording_url:)
    call_log = CallLog.find_by(external_call_id: external_call_id)
    return unless call_log

    call_log.update!(
      status: call_log.order&.confirmed? ? "completed" : "abandoned",
      transcript: transcript,
      recording_url: recording_url,
      ended_at: Time.current
    )
  end

  # Single restaurant pilot: fall back to the only restaurant in the system if the
  # dialed-number lookup comes up empty, so an unexpected field name doesn't hard-fail.
  def self.resolve_restaurant(dialed_number)
    Restaurant.find_by(phone_number: dialed_number) || (Restaurant.count == 1 ? Restaurant.first : nil)
  end
  private_class_method :resolve_restaurant
end

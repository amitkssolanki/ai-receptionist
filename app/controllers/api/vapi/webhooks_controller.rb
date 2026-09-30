# Vapi sends every call event (status changes, tool calls, end-of-call report) to this single server URL.
# This controller is only the adapter: it checks the secret, pulls the provider's fields out of the payload
# and hands them to CallLifecycle / Voice::ToolRunner, which own the behavior. Keep business rules out of here.
#
# Some field paths below (the caller/dialed phone number location within the payload) are a best effort based
# on Vapi's docs, which don't fully spell out the Call object schema. Verify against a real payload (see the
# logger.info dump below, or the ngrok inspector at http://localhost:4040) the first time a call comes through.
class Api::Vapi::WebhooksController < ActionController::API
  before_action :authenticate_vapi!

  def create
    message = params.require(:message).to_unsafe_h
    Rails.logger.info("[Vapi] event: #{message['type']} #{message.except('artifact').to_json}")

    case message["type"]
    when "status-update"
      start_call(message) if message["status"] == "in-progress"
      head :ok
    when "tool-calls"
      run_tool_calls(message)
    when "end-of-call-report"
      finish_call(message)
      head :ok
    else
      # Unhandled event types (transcript, speech-update, etc.) are just acknowledged.
      head :ok
    end
  end

  private

  def authenticate_vapi!
    provided = request.headers["X-Vapi-Secret"].to_s
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, expected_secret)
  end

  def expected_secret
    ENV["VAPI_SERVER_SECRET"].presence || (Rails.env.production? ? SecureRandom.hex : "dev-secret-change-me")
  end

  def start_call(message)
    call = message["call"] || {}
    CallLifecycle.start(
      external_call_id: call["id"],
      dialed_number: call.dig("phoneNumber", "number") || message.dig("phoneNumber", "number"),
      caller_number: message.dig("customer", "number") || call.dig("customer", "number")
    )
  end

  def finish_call(message)
    artifact = message["artifact"] || {}
    CallLifecycle.finish(
      external_call_id: message.dig("call", "id"),
      transcript: artifact["transcript"],
      recording_url: artifact.dig("recording", "stereoUrl") || artifact.dig("recording", "url")
    )
  end

  def run_tool_calls(message)
    call_log = CallLog.find_by(external_call_id: message.dig("call", "id"))
    tool_calls = message["toolCallList"] || []

    results = tool_calls.map do |tool_call|
      { toolCallId: tool_call["id"], result: Voice::ToolRunner.call(call_log: call_log, tool_call: tool_call, vapi_timestamp: message["timestamp"]) }
    end

    render json: { results: results }
  end
end

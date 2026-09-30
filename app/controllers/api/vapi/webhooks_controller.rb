# Vapi sends every call event (status changes, tool calls, end-of-call report) to this single server URL.
# This controller is only the adapter: it checks the secret, pulls the provider's fields out of the payload
# and hands them to CallLifecycle / Voice::ToolRunner, which own the behavior. Keep business rules out of here.
#
# Some field paths below (the caller/dialed phone number location within the payload) are a best effort based
# on Vapi's docs, which don't fully spell out the Call object schema. To inspect a real payload use the ngrok
# inspector at http://localhost:4040; the application itself never logs payloads (they carry phone numbers,
# transcripts and provider URLs).
class Api::Vapi::WebhooksController < ActionController::API
  before_action :authenticate_vapi!

  def create
    message = params.require(:message).to_unsafe_h
    Rails.logger.info("[Vapi] event type=#{loggable(message['type'])} call=#{loggable(call_id(message))}")

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

  # Fails closed: with no usable secret configured every request is refused, in every environment. There is no
  # default. The secret comes from ENV["VAPI_SERVER_SECRET"] or credentials (vapi.server_secret).
  def authenticate_vapi!
    expected = configured_secret
    unless expected
      Rails.logger.error("[Vapi] VAPI_SERVER_SECRET is missing or shorter than #{VapiConfig::MIN_SECRET_LENGTH} characters; refusing webhook requests")
      return head :unauthorized
    end

    provided = request.headers["X-Vapi-Secret"].to_s
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end

  def configured_secret
    VapiConfig.webhook_secret
  end

  # A browser console call passes its signed token as assistant-override metadata when it starts
  # (vapi.start(assistantId, { metadata: { console_token } })); Vapi echoes overrides on the call object.
  def console_token(message, call)
    [ call.dig("assistantOverrides", "metadata"), call["metadata"], message.dig("assistant", "metadata") ]
      .filter_map { |metadata| metadata["console_token"] if metadata.is_a?(Hash) }.first
  end

  def call_id(message)
    call = message["call"]
    call["id"] if call.is_a?(Hash)
  end

  # Only ever used for ids, event types and tool names from an authenticated request: stripped to a short,
  # single-line token so nothing else (and no log injection) can ride along.
  def loggable(value) = value.to_s.gsub(/[^\w.:\-]/, "?").first(64)

  def start_call(message)
    call = message["call"] || {}
    CallLifecycle.start(
      external_call_id: call["id"],
      dialed_number: call.dig("phoneNumber", "number") || message.dig("phoneNumber", "number"),
      caller_number: message.dig("customer", "number") || call.dig("customer", "number"),
      console_token: console_token(message, call)
    )
  end

  def finish_call(message)
    artifact = message["artifact"] || {}
    CallLifecycle.finish(
      external_call_id: message.dig("call", "id"),
      transcript: artifact["transcript"],
      recording_url: artifact.dig("recording", "stereoUrl") || artifact.dig("recording", "url"),
      outcome: { ended_reason: message["endedReason"], duration_seconds: message["durationSeconds"], cost: message["cost"],
                 assistant_version: message["assistantVersion"] }
    )
  end

  def run_tool_calls(message)
    call_log = CallLog.find_by(external_call_id: call_id(message))
    tool_calls = message["toolCallList"] || []

    results = tool_calls.map do |tool_call|
      { toolCallId: tool_call["id"], result: Voice::ToolRunner.call(call_log: call_log, tool_call: tool_call, vapi_timestamp: message["timestamp"]) }
    end
    Rails.logger.info("[Vapi] tool-calls call=#{loggable(call_id(message))} #{tool_call_summary(tool_calls, results)}")

    render json: { results: results }
  end

  # "add_to_cart#toolu_1=ok get_cart#toolu_2=cart_empty": tool name, tool call id and outcome only.
  def tool_call_summary(tool_calls, results)
    tool_calls.zip(results).map do |tool_call, result|
      parsed = JSON.parse(result[:result]) rescue {}
      outcome = parsed["ok"] ? "ok" : (parsed.dig("error", "code") || "unknown")
      "#{loggable(tool_call.dig('function', 'name') || tool_call['name'])}##{loggable(tool_call['id'])}=#{loggable(outcome)}"
    end.join(" ")
  end
end

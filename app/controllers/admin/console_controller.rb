# The voice test console. It is an observer and a remote control: it starts and stops a browser call and shows what
# happened, but every fact about the order comes from the server (see the panels and Admin::Console::*).
class Admin::ConsoleController < Admin::BaseController
  layout "console"

  SESSION_KEY = /\A[0-9a-f]{16,64}\z/
  CALL_ID = /\A[\w-]{1,100}\z/

  # The idle console: generates the session key this page's call will carry. ?assistant=fault_injection (Phase 2, opt-in)
  # calls the deliberately misconfigured fault-injection assistant instead, under a red banner; the server treats its
  # calls exactly like any other.
  def show
    @session_key = SecureRandom.hex(16)
    @fault_injection = params[:assistant] == "fault_injection"
    @problems = VapiConfig.browser_problems(@fault_injection ? "fault_injection" : "development")
    assistant_id = @fault_injection ? VapiConfig.fault_injection_assistant_id : VapiConfig.dev_assistant_id
    @voice = { public_key: VapiConfig.public_key, assistant_id: assistant_id, client_messages: VapiConfig::CLIENT_MESSAGES } if @problems.empty?
  end

  # A fresh signed token for a call about to start (they expire in 15 minutes; the page may have been open for hours).
  def token
    session_key = params[:session_key].to_s
    return head :unprocessable_entity unless session_key.match?(SESSION_KEY)

    render json: { token: ConsoleToken.issue(restaurant: current_restaurant, session_key: session_key) }
  end

  # Fallback attach. The normal path is the signed console token (the server tells the page which call is its own). If the
  # token never reaches the webhook, the browser still learns its call id from the Vapi SDK and asks to be attached to it.
  # Scoped to the signed-in user's restaurant, and "not there yet" and "not yours" answer identically.
  def attach
    call_id = params[:call_id].to_s
    return head :unprocessable_entity unless call_id.match?(CALL_ID)

    call_log = current_restaurant.call_logs.find_by(external_call_id: call_id)
    return render(json: { status: "pending" }, status: :accepted) unless call_log

    Rails.logger.info("[Console] attached call #{call_log.id} by call id (no console token)")
    render turbo_stream: turbo_stream.update("console-call", partial: "admin/console/call_attached", locals: { call_log: call_log, via: "call_id" })
  end

  # Observe an in-progress call, or review a past one. Only calls of the signed-in user's restaurant exist here.
  def call
    @call_log = current_restaurant.call_logs.find(params[:id])
  end

  # The call's persisted server-side state (status, order board, server events): the source a browser rebuilds from on
  # first render, refresh and Action Cable reconnect. Rendered straight from the database.
  def state
    @call_log = current_restaurant.call_logs.find(params[:id])
    render layout: false
  end
end

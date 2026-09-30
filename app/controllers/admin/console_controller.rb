# The voice test console. It is an observer and a remote control: it starts and stops a browser call and shows what
# happened, but every fact about the order comes from the server (see the panels and Admin::Console::*).
class Admin::ConsoleController < Admin::BaseController
  layout "console"

  SESSION_KEY = /\A[0-9a-f]{16,64}\z/

  # The idle console: generates the session key this page's call will carry.
  def show
    @session_key = SecureRandom.hex(16)
    @problems = VapiConfig.browser_problems
    @voice = { public_key: VapiConfig.public_key, assistant_id: VapiConfig.dev_assistant_id, client_messages: VapiConfig::CLIENT_MESSAGES } if @problems.empty?
  end

  # A fresh signed token for a call about to start (they expire in 15 minutes; the page may have been open for hours).
  def token
    session_key = params[:session_key].to_s
    return head :unprocessable_entity unless session_key.match?(SESSION_KEY)

    render json: { token: ConsoleToken.issue(restaurant: current_restaurant, session_key: session_key) }
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

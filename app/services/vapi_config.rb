# What the repository says the development Vapi assistant must look like. The repository is the source of truth:
#   config/vapi/tools.json       the exact function definitions to paste into Vapi
#   config/vapi/assistant.json   every other dashboard setting the plan fixes (machine-readable)
#   config/vapi/assistant.md     the human checklist for setting them up by hand
#   docs/voice_agent/system_prompt.md   the system prompt
# Nothing here writes to Vapi. VapiConfig::DriftCheck compares these files with what Vapi reports (bin/rails vapi:check).
module VapiConfig
  BASELINE_ASSISTANT_ID = "8f2053ae-d72d-4c8d-b96e-4d9facd1f618".freeze # the frozen "before" assistant: never the dev one
  WEBHOOK_PATH = "/api/vapi/webhooks".freeze
  SECRET_HEADER = "X-Vapi-Secret".freeze
  MIN_SECRET_LENGTH = 16

  module_function

  def tools = JSON.parse(Rails.root.join("config/vapi/tools.json").read)
  def settings = JSON.parse(Rails.root.join("config/vapi/assistant.json").read)
  def system_prompt = Rails.root.join("docs/voice_agent/system_prompt.md").read

  # The webhook secret Rails expects: ENV["VAPI_SERVER_SECRET"] or credentials vapi.server_secret. nil when unset or
  # too short to be a secret. Shared by the webhook controller and the drift check.
  def webhook_secret
    secret = ENV["VAPI_SERVER_SECRET"].presence || Rails.application.credentials.dig(:vapi, :server_secret).presence
    secret if secret.to_s.length >= MIN_SECRET_LENGTH
  end

  # What the browser console may be given: Vapi's restricted PUBLIC key (safe for client-side use; restricted in the
  # Vapi dashboard to the dev assistant, the console origins and no transient assistants) and the dev assistant's id.
  # Never the private key or the webhook secret. nil when not configured.
  def public_key = ENV["VAPI_PUBLIC_KEY"].presence || Rails.application.credentials.dig(:vapi, :public_key).presence

  # Client messages the console asks Vapi to send over the data channel (set per call, not on the assistant).
  CLIENT_MESSAGES = %w[transcript speech-update status-update tool-calls user-interrupted hang].freeze

  # Why the console cannot start a call right now; empty when it can. Shown on the page, never a secret.
  def browser_problems
    problems = []
    problems << "No Vapi public key is configured (set VAPI_PUBLIC_KEY or credentials vapi.public_key: the restricted browser key, never the private key)." if public_key.blank?
    if dev_assistant_id.blank?
      problems << "No development assistant id is configured (set VAPI_DEV_ASSISTANT_ID or credentials vapi.dev_assistant_id)."
    elsif dev_assistant_id == BASELINE_ASSISTANT_ID
      problems << "The configured assistant is the frozen baseline assistant; the console only uses the development assistant."
    end
    problems
  end

  # Read-only credentials for vapi:check. Never printed.
  def private_key = ENV["VAPI_PRIVATE_KEY"].presence || Rails.application.credentials.dig(:vapi, :private_key).presence
  def dev_assistant_id = ENV["VAPI_DEV_ASSISTANT_ID"].presence || Rails.application.credentials.dig(:vapi, :dev_assistant_id).presence
end

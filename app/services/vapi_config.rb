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

  # An assistant the repository describes, as vapi:check compares it. :development is the normal assistant.
  # :fault_injection is a deliberately misbehaving copy for the demonstration (Phase 2): the same settings, tools and
  # webhook, its own name and first message (config/vapi/fault_injection.json, nothing else), and the normal system
  # prompt followed by config/vapi/fault_injection_prompt.md. Both reach the same server path; nothing on the server
  # depends on which assistant a call came from. excluded_ids: assistants the profile must never be checked against.
  Profile = Data.define(:key, :settings, :system_prompt, :assistant_id, :excluded_ids) do
    def fault_injection? = key == :fault_injection
  end

  PROFILES = %w[development fault_injection].freeze

  def profile(key = "development")
    case key.to_s
    when "development"
      Profile.new(key: :development, settings: settings, system_prompt: system_prompt, assistant_id: dev_assistant_id,
                  excluded_ids: [ BASELINE_ASSISTANT_ID ])
    when "fault_injection"
      Profile.new(key: :fault_injection, settings: settings.merge(fault_injection_overrides),
                  system_prompt: "#{system_prompt.rstrip}\n\n#{fault_injection_prompt}", assistant_id: fault_injection_assistant_id,
                  excluded_ids: [ BASELINE_ASSISTANT_ID, dev_assistant_id ].compact)
    else
      raise ArgumentError, "unknown Vapi profile #{key.to_s.inspect} (expected #{PROFILES.join(' or ')})"
    end
  end

  def fault_injection_overrides = JSON.parse(Rails.root.join("config/vapi/fault_injection.json").read)
  def fault_injection_prompt = Rails.root.join("config/vapi/fault_injection_prompt.md").read

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

  # Why the console cannot start a call right now; empty when it can. Shown on the page, never a secret. The
  # fault-injection console (opt-in) never falls back to the development assistant.
  def browser_problems(profile = "development")
    problems = []
    problems << "No Vapi public key is configured (set VAPI_PUBLIC_KEY or credentials vapi.public_key: the restricted browser key, never the private key)." if public_key.blank?
    if profile.to_s == "fault_injection"
      id = fault_injection_assistant_id
      if id.blank?
        problems << "No fault-injection assistant id is configured (set VAPI_FAULT_INJECTION_ASSISTANT_ID or credentials vapi.fault_injection_assistant_id; see config/vapi/fault_injection.md)."
      elsif [ BASELINE_ASSISTANT_ID, dev_assistant_id ].include?(id)
        problems << "The configured fault-injection assistant is the development or baseline assistant; it must be a separate assistant."
      end
    elsif dev_assistant_id.blank?
      problems << "No development assistant id is configured (set VAPI_DEV_ASSISTANT_ID or credentials vapi.dev_assistant_id)."
    elsif dev_assistant_id == BASELINE_ASSISTANT_ID
      problems << "The configured assistant is the frozen baseline assistant; the console only uses the development assistant."
    end
    problems
  end

  # Read-only credentials for vapi:check. Never printed.
  def private_key = ENV["VAPI_PRIVATE_KEY"].presence || Rails.application.credentials.dig(:vapi, :private_key).presence
  def dev_assistant_id = ENV["VAPI_DEV_ASSISTANT_ID"].presence || Rails.application.credentials.dig(:vapi, :dev_assistant_id).presence

  # The fault-injection assistant (a separate Vapi assistant; see config/vapi/fault_injection.md). nil when not set up.
  def fault_injection_assistant_id
    ENV["VAPI_FAULT_INJECTION_ASSISTANT_ID"].presence || Rails.application.credentials.dig(:vapi, :fault_injection_assistant_id).presence
  end
end

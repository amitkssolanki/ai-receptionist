require "test_helper"

# The fault-injection profile (Phase 2): a separate Vapi assistant that is the development assistant plus a committed
# prompt appendix, a name and a first message, and nothing else. vapi:check PROFILE=fault_injection uses it.
class VapiConfig::FaultInjectionProfileTest < ActiveSupport::TestCase
  SECRET = "0123456789abcdef0123456789abcdef".freeze # explicit test value, not a credential
  FAULT_ID = "99999999-8888-7777-6666-555555555555".freeze
  DEV_ID = "11111111-2222-3333-4444-555555555555".freeze

  def fault_profile(assistant_id: FAULT_ID, dev_id: DEV_ID)
    VapiConfig.profile("fault_injection").with(assistant_id: assistant_id, excluded_ids: [ VapiConfig::BASELINE_ASSISTANT_ID, dev_id ])
  end

  # An assistant exactly as a profile describes it, in the shape the Vapi API returns.
  def assistant_for(profile, id:)
    settings = profile.settings
    {
      "id" => id, "name" => settings["name"],
      "model" => settings["model"].merge("messages" => [ { "role" => "system", "content" => profile.system_prompt } ]),
      "voice" => settings["voice"], "transcriber" => settings["transcriber"].merge("languages" => [ "en" ]),
      "firstMessage" => settings["firstMessage"], "maxDurationSeconds" => settings["maxDurationSeconds"],
      "serverMessages" => settings["serverMessages"],
      "server" => { "url" => "https://demo.example.ngrok.app#{VapiConfig::WEBHOOK_PATH}", "timeoutSeconds" => 20, "headers" => { "X-Vapi-Secret" => SECRET } }
    }
  end

  def fault_assistant = assistant_for(fault_profile, id: FAULT_ID)
  def tools = VapiConfig.tools.map { |t| t.deep_dup.merge("id" => SecureRandom.uuid) }

  def check(assistant: fault_assistant, profile: fault_profile, tools: self.tools)
    VapiConfig::DriftCheck.new(assistant: assistant, tools: tools, webhook_secret: SECRET, profile: profile).call
  end

  def messages(report) = report.errors.map { |f| "#{f.area}: #{f.message}" }

  def assert_drift(report, pattern)
    assert_not report.clean?, "expected drift matching #{pattern.inspect}"
    assert(messages(report).any? { |m| m.match?(pattern) }, "no finding matched #{pattern.inspect} in #{messages(report).inspect}")
  end

  test "the profile is the development profile plus a name, a first message and the appended prompt, nothing else" do
    development = VapiConfig.profile
    fault = VapiConfig.profile("fault_injection")

    assert_equal %w[firstMessage name], VapiConfig.fault_injection_overrides.keys.sort
    assert_equal development.settings.except("name", "firstMessage"), fault.settings.except("name", "firstMessage")
    assert_equal "Taj Zayka Receptionist (FAULT INJECTION)", fault.settings["name"]
    assert_match(/fault-injection test assistant/, fault.settings["firstMessage"])
    assert fault.system_prompt.start_with?(development.system_prompt.rstrip), "the fault prompt must begin with the whole normal prompt"
    assert fault.system_prompt.end_with?(VapiConfig.fault_injection_prompt), "the fault prompt must end with the committed appendix"
    assert_predicate fault, :fault_injection?
    assert_not development.fault_injection?
  end

  test "the appendix carries exactly the two approved faults" do
    appendix = VapiConfig.fault_injection_prompt
    assert_match(/FAULT INJECTION/, appendix)
    assert_match(/As soon as get_cart returns, call submit_order straight away/, appendix)
    assert_includes appendix, %(say exactly: "I've added a free garlic knots to your order")
  end

  test "an assistant built from the fault-injection profile is clean" do
    report = check
    assert_empty messages(report)
    assert_empty report.warnings
  end

  test "the normal prompt alone, the appendix alone or an edited appendix is drift" do
    [ VapiConfig.system_prompt, VapiConfig.fault_injection_prompt,
      fault_profile.system_prompt.sub("straight away", "after the caller confirms") ].each do |prompt|
      assistant = fault_assistant.deep_merge("model" => { "messages" => [ { "role" => "system", "content" => prompt } ] })
      assert_drift check(assistant: assistant), /system prompt differs from .*fault_injection_prompt\.md/
    end
  end

  test "tools and webhook are held to the same contract as the development assistant" do
    edited = tools.each { |t| t["function"]["description"] = "Submit now." if t.dig("function", "name") == "submit_order" }
    assert_drift check(tools: edited), /submit_order: description differs/
    assert_drift check(tools: tools.reject { |t| t.dig("function", "name") == "get_cart" }), /missing tool get_cart/

    elsewhere = fault_assistant.deep_merge("server" => { "url" => "https://demo.example.ngrok.app/api/other" })
    assert_drift check(assistant: elsewhere), /server URL path is "\/api\/other"/
    no_secret = fault_assistant.tap { |a| a["server"] = a["server"].merge("headers" => {}) }
    assert_drift check(assistant: no_secret), /webhook secret: missing/
  end

  test "a wrong name or first message is drift, not a warning: the assistant must say what it is" do
    assert_drift check(assistant: fault_assistant.merge("name" => "Taj Zayka Receptionist (dev)")), /name is "Taj Zayka Receptionist \(dev\)"/
    assert_drift check(assistant: fault_assistant.merge("firstMessage" => VapiConfig.settings["firstMessage"])), /firstMessage differs from config\/vapi\/fault_injection\.json/
  end

  test "the development assistant, the baseline assistant or an unconfigured id is never accepted as the fault assistant" do
    assert_drift check(assistant: fault_assistant.merge("id" => DEV_ID), profile: fault_profile(assistant_id: nil)), /this is the development assistant/
    assert_drift check(assistant: fault_assistant.merge("id" => VapiConfig::BASELINE_ASSISTANT_ID), profile: fault_profile(assistant_id: nil)), /frozen baseline assistant/
    assert_drift check(assistant: fault_assistant.merge("id" => "00000000-0000-0000-0000-000000000000")), /is not the configured fault_injection assistant/
  end

  test "each profile rejects the other's assistant" do
    development_assistant = assistant_for(VapiConfig.profile, id: DEV_ID)
    assert_drift check(assistant: development_assistant.merge("id" => FAULT_ID)), /system prompt differs/

    report = VapiConfig::DriftCheck.new(assistant: fault_assistant, tools: tools, webhook_secret: SECRET).call
    assert_drift report, /system prompt differs from docs\/voice_agent\/system_prompt\.md \(/
  end

  test "the development profile is the default and an unknown profile is refused" do
    assert_equal VapiConfig.profile("development"), VapiConfig.profile
    assert_raises(ArgumentError) { VapiConfig.profile("production") }
  end
end

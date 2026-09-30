require "test_helper"

class VapiConfig::DriftCheckTest < ActiveSupport::TestCase
  SECRET = "0123456789abcdef0123456789abcdef".freeze # explicit test value, not a credential

  # An assistant exactly as the repository describes it, in the shape the Vapi API returns.
  def conformant
    settings = VapiConfig.settings
    {
      "id" => "11111111-2222-3333-4444-555555555555", "name" => settings["name"],
      "model" => settings["model"].merge("messages" => [ { "role" => "system", "content" => VapiConfig.system_prompt } ]),
      "voice" => settings["voice"], "transcriber" => settings["transcriber"].merge("languages" => [ "en" ]),
      "firstMessage" => settings["firstMessage"], "maxDurationSeconds" => settings["maxDurationSeconds"],
      "serverMessages" => settings["serverMessages"],
      "server" => { "url" => "https://demo.example.ngrok.app#{VapiConfig::WEBHOOK_PATH}", "timeoutSeconds" => 20, "headers" => { "X-Vapi-Secret" => SECRET } }
    }
  end

  def conformant_tools = VapiConfig.tools.map { |t| t.deep_dup.merge("id" => SecureRandom.uuid) }

  def check(assistant: conformant, tools: conformant_tools, secret: SECRET, host: nil)
    VapiConfig::DriftCheck.new(assistant: assistant, tools: tools, webhook_secret: secret, expected_host: host).call
  end

  def messages(report) = report.errors.map { |f| "#{f.area}: #{f.message}" }

  def assert_drift(report, pattern)
    assert_not report.clean?, "expected drift matching #{pattern.inspect}"
    assert(messages(report).any? { |m| m.match?(pattern) }, "no finding matched #{pattern.inspect} in #{messages(report).inspect}")
  end

  def tool(tools, name) = tools.find { |t| t.dig("function", "name") == name }

  test "an assistant built from the repository files is clean" do
    report = check
    assert_empty messages(report)
    assert_predicate report, :clean?
    assert_empty report.warnings
  end

  # --- tools ---

  test "an assistant with no tools is the call #6 failure" do
    assert_drift check(tools: []), /the assistant has no tools \(expected 8\)/
  end

  test "each missing tool is named" do
    tools = conformant_tools.reject { |t| %w[get_menu_item get_cart].include?(t.dig("function", "name")) }
    report = check(tools: tools)
    assert_drift report, /missing tool get_menu_item/
    assert_drift report, /missing tool get_cart/
  end

  test "an unexpected tool, one the server cannot handle, is flagged" do
    extra = { "id" => SecureRandom.uuid, "type" => "function", "function" => { "name" => "issue_refund", "parameters" => { "type" => "object", "properties" => {} } } }
    assert_drift check(tools: conformant_tools + [ extra ]), /unexpected tool "issue_refund"/
  end

  test "a tool attached twice is flagged" do
    assert_drift check(tools: conformant_tools + [ conformant_tools.first ]), /attached 2 times/
  end

  test "submit_order without cart_version (the pre-Step 5 definition) is caught" do
    tools = conformant_tools
    params = tool(tools, "submit_order")["function"]["parameters"]
    params["properties"].delete("cart_version")
    params["required"] -= [ "cart_version" ]
    report = check(tools: tools)
    assert_drift report, /submit_order: argument cart_version is missing/
    assert_drift report, /submit_order: required arguments are \["fulfillment_type"\]/
  end

  test "a changed argument type, enum or an extra argument is caught" do
    tools = conformant_tools
    tool(tools, "add_to_cart")["function"]["parameters"]["properties"]["quantity"]["type"] = "string"
    tool(tools, "submit_order")["function"]["parameters"]["properties"]["fulfillment_type"]["enum"] = %w[pickup delivery dine_in]
    tool(tools, "get_menu_item")["function"]["parameters"]["properties"]["price"] = { "type" => "number" }
    tool(tools, "add_to_cart")["function"]["parameters"]["properties"]["modifier_ids"]["items"]["type"] = "string"
    report = check(tools: tools)
    assert_drift report, /add_to_cart: argument quantity: type is "string", expected "integer"/
    assert_drift report, /submit_order: argument fulfillment_type: enum is/
    assert_drift report, /get_menu_item: unexpected argument price/
    assert_drift report, /add_to_cart: argument modifier_ids: items type is "string"/
  end

  test "an edited tool description is drift (it is the model's instruction)" do
    tools = conformant_tools
    tool(tools, "submit_order")["function"]["description"] = "Submit the order."
    assert_drift check(tools: tools), /submit_order: description differs/
  end

  test "whitespace-only description differences are not drift" do
    tools = conformant_tools
    tool(tools, "get_cart")["function"]["description"] = "  #{tool(tools, 'get_cart')['function']['description'].gsub(' ', '  ')}\n"
    assert_predicate check(tools: tools), :clean?
  end

  test "asynchronous tools and per-tool server overrides are flagged" do
    tools = conformant_tools
    tool(tools, "get_cart")["async"] = true
    tool(tools, "add_to_cart")["server"] = { "url" => "https://elsewhere.example/hook" }
    report = check(tools: tools)
    assert_drift report, /get_cart: is asynchronous/
    assert_drift report, /add_to_cart: has its own server override/
  end

  # --- prompt ---

  test "a missing or edited system prompt is caught" do
    assistant = conformant
    assistant["model"]["messages"] = []
    assert_drift check(assistant: assistant), /no system prompt/

    assistant = conformant
    assistant["model"]["messages"][0]["content"] = VapiConfig.system_prompt.sub("Never submit an order the caller hasn't confirmed.", "Submit whenever.")
    assert_drift check(assistant: assistant), /system prompt differs from docs\/voice_agent\/system_prompt.md \(1 repo lines absent, 1 extra lines/
  end

  test "prompt whitespace and line wrapping differences are not drift" do
    assistant = conformant
    assistant["model"]["messages"][0]["content"] = VapiConfig.system_prompt.gsub("\n", "\r\n").gsub("  ", " ") + "\n\n"
    assert_predicate check(assistant: assistant), :clean?
  end

  # --- settings and limits ---

  test "model, voice and transcriber drift is caught" do
    assistant = conformant
    assistant["model"]["model"] = "gpt-4o"
    assistant["model"]["reasoningEffort"] = "high"
    assistant["voice"] = assistant["voice"].merge("voiceId" => "Someone")
    assistant["transcriber"] = assistant["transcriber"].merge("model" => "other")
    report = check(assistant: assistant)
    assert_drift report, /model: model is openai\/gpt-4o/
    assert_drift report, /model: reasoningEffort is "high"/
    assert_drift report, /voice: voiceId is "Someone"/
    assert_drift report, /transcriber: model is "other"/
  end

  test "the 300 second limit is enforced, including when it is missing" do
    [ 600, nil ].each do |value|
      assistant = conformant.merge("maxDurationSeconds" => value)
      assert_drift check(assistant: assistant), /maxDurationSeconds is #{value.inspect}, expected 300/
    end
  end

  test "serverMessages must be exactly status-update, tool-calls and end-of-call-report" do
    [ nil, %w[tool-calls], %w[status-update tool-calls end-of-call-report speech-update] ].each do |value|
      assert_drift check(assistant: conformant.merge("serverMessages" => value)), /serverMessages are #{Regexp.escape(value.inspect)}/
    end
    assert_predicate check(assistant: conformant.merge("serverMessages" => %w[end-of-call-report tool-calls status-update])), :clean?
  end

  test "a backoffPlan is flagged" do
    assert_drift check(assistant: conformant.merge("backoffPlan" => { "type" => "fixed" })), /backoffPlan/
  end

  # --- webhook ---

  test "server URL: missing, wrong path, http, or the wrong host" do
    assistant = conformant
    assistant["server"] = assistant["server"].merge("url" => nil)
    assert_drift check(assistant: assistant), /no server URL/

    assistant = conformant
    assistant["server"]["url"] = "https://demo.example.ngrok.app/api/voice/calls"
    assert_drift check(assistant: assistant), /server URL path is "\/api\/voice\/calls"/

    assistant = conformant
    assistant["server"]["url"] = "http://demo.example.ngrok.app#{VapiConfig::WEBHOOK_PATH}"
    assert_drift check(assistant: assistant), /must use https/

    assert_drift check(host: "other.ngrok.app"), /server URL host is demo.example.ngrok.app, expected other.ngrok.app/
    assert_predicate check(host: "demo.example.ngrok.app"), :clean?
  end

  test "webhook secret: matching is clean, and only the verdict is ever reported" do
    assert_predicate check, :clean?

    mismatch = check(assistant: conformant.tap { |a| a["server"]["headers"]["X-Vapi-Secret"] = "f" * 32 })
    assert_drift mismatch, /webhook secret: mismatch/

    missing = check(assistant: conformant.tap { |a| a["server"]["headers"] = {} })
    assert_drift missing, /webhook secret: missing/

    rails_unset = check(secret: nil)
    assert_drift rails_unset, /webhook secret: Rails has no usable VAPI_SERVER_SECRET/

    [ mismatch, missing, rails_unset ].each do |report|
      text = report.findings.map(&:message).join(" ")
      assert_no_match(/#{SECRET}|#{'f' * 32}/, text, "a secret value appeared in a finding")
    end
  end

  test "a redacted secret from the API is reported as unverifiable, not as a mismatch" do
    report = check(assistant: conformant.tap { |a| a["server"]["headers"]["X-Vapi-Secret"] = "<REDACTED>" })
    assert_predicate report, :clean?
    assert_equal [ "webhook secret" ], report.warnings.map(&:area)
    assert_match(/unverifiable/, report.warnings.first.message)
  end

  test "the header name is matched case-insensitively" do
    assistant = conformant.tap { |a| a["server"]["headers"] = { "x-vapi-secret" => SECRET } }
    assert_predicate check(assistant: assistant), :clean?
  end

  # --- the frozen baseline is not the dev assistant ---

  test "the frozen baseline assistant is refused outright" do
    assert_drift check(assistant: conformant.merge("id" => VapiConfig::BASELINE_ASSISTANT_ID)), /frozen baseline assistant/
  end

  test "the real baseline assistant, as captured with call #7, shows the documented differences" do
    captured = JSON.parse(Rails.root.join("test/fixtures/files/baseline/call7/assistant_config.json").read)
    report = check(assistant: captured.merge("id" => "captured-baseline-copy"), tools: captured.dig("model", "tools"), secret: SECRET)
    text = messages(report).join("\n")

    assert_match(/missing tool get_menu_item/, text)
    assert_match(/submit_order: argument cart_version is missing/, text)
    assert_match(/system prompt differs/, text)
    assert_match(/serverMessages are nil/, text)
    assert_not_predicate report, :clean?
  end
end

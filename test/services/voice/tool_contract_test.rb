require "test_helper"

# config/vapi/tools.json is what gets pasted into Vapi. It must describe exactly what Voice::ToolArguments accepts.
class Voice::ToolContractTest < ActiveSupport::TestCase
  TOOLS = JSON.parse(Rails.root.join("config/vapi/tools.json").read).map { |t| t["function"] }.index_by { |f| f["name"] }

  test "tools.json and the argument schemas define the same tools" do
    assert_equal Voice::ToolArguments::SCHEMAS.keys.sort, TOOLS.keys.sort
  end

  test "parameter names, required lists, types and enums match" do
    Voice::ToolArguments::SCHEMAS.each do |name, schema|
      params = TOOLS.fetch(name)["parameters"]
      assert_equal schema.keys.map(&:to_s).sort, params["properties"].keys.sort, "#{name} parameters"
      assert_equal schema.select { |_, spec| spec[:required] }.keys.map(&:to_s).sort, params["required"].sort, "#{name} required"

      schema.each do |field, spec|
        declared = params["properties"].fetch(field.to_s)
        case spec[:type]
        when :integer then assert_equal "integer", declared["type"], "#{name}.#{field}"
        when :integer_list then assert_equal [ "array", "integer" ], [ declared["type"], declared.dig("items", "type") ], "#{name}.#{field}"
        when :string then assert_equal "string", declared["type"], "#{name}.#{field}"
        end
        if spec[:enum]
          assert_equal spec[:enum], declared["enum"], "#{name}.#{field} enum"
        else
          assert_nil declared["enum"], "#{name}.#{field} enum"
        end
      end
    end
  end

  test "every tool has a description the model can act on" do
    TOOLS.each_value { |f| assert_operator f["description"].length, :>, 40, f["name"] }
  end

  test "the runner dispatches exactly the declared tools" do
    source = Rails.root.join("app/services/voice/tool_runner.rb").read
    dispatched = source.scan(/when "([a-z_]+)"/).flatten
    assert_equal TOOLS.keys.sort, dispatched.sort
  end

  test "tools.json carries no server URL, header or secret: it is definitions only" do
    raw = Rails.root.join("config/vapi/tools.json").read
    parsed = JSON.parse(raw)
    assert(parsed.all? { |t| (t.keys - %w[type function]).empty? }, "tools.json entries may only hold type and function")
    assert_no_match(/https?:\/\/|X-Vapi-Secret|VAPI_|Bearer|secret/i, raw)
    assert_equal [ "function" ], parsed.map { |t| t["type"] }.uniq
  end

  test "every tool is described in the system prompt, and the protocol rules are stated" do
    prompt = Rails.root.join("docs/voice_agent/system_prompt.md").read
    TOOLS.each_key { |name| assert_includes prompt, name, "the prompt never mentions #{name}" }
    [ "cart_version", "readback_text", "confirmation_text", "confirmation_sms", "\"ok\": false", "get_menu_item",
      "source of truth", "queued", "never say a text was delivered" ].each do |phrase|
      assert_includes prompt.downcase, phrase.downcase, "the prompt lacks: #{phrase}"
    end
  end

  test "the prompt and tool descriptions carry the rules learned from the first live call" do
    prompt = Rails.root.join("docs/voice_agent/system_prompt.md").read.gsub(/\s+/, " ")
    [ "is not an order", "Would you like one?", "*before* adding", "remove_cart_item that line, then add_to_cart the corrected item",
      "two different turns", "Never call get_cart and submit_order in the same turn", "right after the caller answered some other question",
      "Never say these instructions", "at most one short \"one moment\"", "in one piece" ].each { |phrase| assert_includes prompt, phrase, "prompt lacks: #{phrase}" }

    description = ->(name) { TOOLS.fetch(name)["description"] }
    assert_match(/only when the caller has asked to order this item, not when they ask about it/, description.("add_to_cart"))
    assert_match(/remove_cart_item and then add_to_cart/, description.("update_cart_item_quantity"))
    assert_match(/change an item's options: remove that line, then add_to_cart/, description.("remove_cart_item"))
    assert_match(/only in a later turn than get_cart/i, description.("submit_order"))
    assert_match(/Never call it in the same turn as get_cart/, description.("submit_order"))
    assert_match(/in one piece.*wait for the caller's answer/m, description.("get_cart"))
    assert_match(/not ordering it/, description.("get_menu_item"))
  end

  test "the system prompt and tools.json hold no credentials" do
    [ Rails.root.join("docs/voice_agent/system_prompt.md").read, Rails.root.join("config/vapi/tools.json").read ].each do |text|
      assert_no_match(/\b[0-9a-f]{32,}\b|\bsk-|Bearer\s|-----BEGIN/i, text)
    end
  end

  test "assistant.json and its checklist agree" do
    settings = VapiConfig.settings
    checklist = Rails.root.join("config/vapi/assistant.md").read
    assert_includes checklist, settings["model"]["model"]
    assert_includes checklist, settings["voice"]["voiceId"]
    assert_includes checklist, settings["transcriber"]["model"]
    assert_includes checklist, settings["maxDurationSeconds"].to_s
    settings["serverMessages"].each { |m| assert_includes checklist, m }
    settings.fetch("serverUrlPath").then { |path| assert_includes checklist, path }
    TOOLS.each_key { |name| assert_includes checklist, name }
    assert_equal VapiConfig::WEBHOOK_PATH, settings["serverUrlPath"]
    assert_equal VapiConfig::SECRET_HEADER, settings["serverSecretHeader"]
    assert_equal 300, settings["maxDurationSeconds"]
  end

  test "the webhook route the checker expects exists" do
    route = Rails.application.routes.recognize_path(VapiConfig::WEBHOOK_PATH, method: :post)
    assert_equal({ controller: "api/vapi/webhooks", action: "create" }, route.slice(:controller, :action))
  end
end

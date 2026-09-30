# Compares what Vapi reports for the development assistant with what the repository expects and lists every
# difference that matters to the Rails contract. Pure: it takes already-fetched data, does no I/O and never sees a
# Vapi credential. Findings are :error (the assistant will misbehave or break) or :warn (cannot be verified / cosmetic).
module VapiConfig
  class DriftCheck
    Finding = Data.define(:level, :area, :message)

    Report = Data.define(:findings) do
      def errors = findings.select { |f| f.level == :error }
      def warnings = findings.select { |f| f.level == :warn }
      def clean? = errors.empty?
    end

    SCHEMA_KEYS = %w[type enum maxLength].freeze

    # assistant: the GET /assistant/:id body. tools: every tool the assistant uses (inline model.tools plus the
    # bodies fetched for model.toolIds). webhook_secret: what Rails expects (nil when Rails has none).
    def initialize(assistant:, tools:, webhook_secret:, expected_host: nil)
      @assistant = assistant
      @tools = tools
      @webhook_secret = webhook_secret
      @expected_host = expected_host
      @findings = []
    end

    def call
      check_identity
      check_tools
      check_prompt
      check_settings
      check_server
      Report.new(findings: @findings)
    end

    private

    def error(area, message) = @findings << Finding.new(:error, area, message)
    def warn(area, message) = @findings << Finding.new(:warn, area, message)

    def model = @assistant["model"] || {}
    def expected = VapiConfig.settings

    def check_identity
      return unless @assistant["id"] == VapiConfig::BASELINE_ASSISTANT_ID

      error("assistant", "this is the frozen baseline assistant, not the development assistant; it must never be aligned or used here")
    end

    # --- tools ---

    def check_tools
      expected_tools = VapiConfig.tools.to_h { |t| [ t.dig("function", "name"), t ] }
      actual_tools = @tools.select { |t| t["type"].nil? || t["type"] == "function" }.group_by { |t| t.dig("function", "name") }

      error("tools", "the assistant has no tools (expected #{expected_tools.size})") if @tools.empty?
      (expected_tools.keys - actual_tools.keys).each { |n| error("tools", "missing tool #{n}") } unless @tools.empty?
      (actual_tools.keys - expected_tools.keys).each { |n| error("tools", "unexpected tool #{n.inspect} (the server has no handler for it)") }
      actual_tools.each { |n, list| error("tools", "tool #{n} is attached #{list.size} times") if list.size > 1 }

      (expected_tools.keys & actual_tools.keys).each do |name|
        compare_tool(name, expected_tools[name], actual_tools[name].first)
      end
    end

    def compare_tool(name, expected_tool, actual_tool)
      parameter_differences(expected_tool.dig("function", "parameters"), actual_tool.dig("function", "parameters") || {}).each do |difference|
        error("tools", "#{name}: #{difference}")
      end
      if normalize(expected_tool.dig("function", "description")) != normalize(actual_tool.dig("function", "description"))
        error("tools", "#{name}: description differs from config/vapi/tools.json (the model's instructions for the tool)")
      end
      error("tools", "#{name}: is asynchronous; tools must be synchronous so the model waits for the server's answer") if actual_tool["async"] == true
      error("tools", "#{name}: has its own server override; it must use the assistant's server URL") if actual_tool["server"].present?
    end

    def parameter_differences(expected_params, actual_params)
      expected_props = expected_params["properties"] || {}
      actual_props = actual_params["properties"] || {}
      diffs = (expected_props.keys - actual_props.keys).map { |a| "argument #{a} is missing" }
      diffs += (actual_props.keys - expected_props.keys).map { |a| "unexpected argument #{a}" }
      (expected_props.keys & actual_props.keys).each do |arg|
        e = expected_props[arg]
        a = actual_props[arg]
        SCHEMA_KEYS.each do |key|
          diffs << "argument #{arg}: #{key} is #{a[key].inspect}, expected #{e[key].inspect}" if e[key] != a[key]
        end
        diffs << "argument #{arg}: items type is #{a.dig('items', 'type').inspect}, expected #{e.dig('items', 'type').inspect}" if e.dig("items", "type") != a.dig("items", "type")
      end
      expected_required = Array(expected_params["required"]).sort
      actual_required = Array(actual_params["required"]).sort
      diffs << "required arguments are #{actual_required.inspect}, expected #{expected_required.inspect}" if expected_required != actual_required
      diffs
    end

    # --- prompt ---

    def check_prompt
      messages = model["messages"] || []
      system = messages.select { |m| m["role"] == "system" }
      return error("prompt", "the assistant has no system prompt") if system.empty?

      error("prompt", "#{system.size} system messages; expected exactly one") if system.size > 1
      return if normalize(system.first["content"]) == normalize(VapiConfig.system_prompt)

      error("prompt", "system prompt differs from docs/voice_agent/system_prompt.md (#{prompt_difference(system.first['content'])})")
    end

    def prompt_difference(actual)
      expected_lines = normalized_lines(VapiConfig.system_prompt)
      actual_lines = normalized_lines(actual)
      "#{(expected_lines - actual_lines).size} repo lines absent, #{(actual_lines - expected_lines).size} extra lines in Vapi"
    end

    # --- settings ---

    def check_settings
      error("model", "model is #{model['provider']}/#{model['model']}, expected #{expected.dig('model', 'provider')}/#{expected.dig('model', 'model')}") if
        model["provider"] != expected.dig("model", "provider") || model["model"] != expected.dig("model", "model")
      reasoning = expected.dig("model", "reasoningEffort")
      error("model", "reasoningEffort is #{model['reasoningEffort'].inspect}, expected #{reasoning.inspect}") if model["reasoningEffort"] != reasoning

      compare_subset("voice", @assistant["voice"], expected["voice"])
      compare_subset("transcriber", @assistant["transcriber"], expected["transcriber"])

      if @assistant["maxDurationSeconds"] != expected["maxDurationSeconds"]
        error("limits", "maxDurationSeconds is #{@assistant['maxDurationSeconds'].inspect}, expected #{expected['maxDurationSeconds']} (demo cost protection)")
      end
      actual_messages = Array(@assistant["serverMessages"]).sort
      if actual_messages != expected["serverMessages"].sort
        error("events", "serverMessages are #{@assistant['serverMessages'].inspect}, expected #{expected['serverMessages']} (status-update starts the call record, end-of-call-report ends it)")
      end
      error("settings", "a backoffPlan is set; it must not be") if @assistant["backoffPlan"].present?
      warn("settings", "firstMessage differs from config/vapi/assistant.json") if normalize(@assistant["firstMessage"]) != normalize(expected["firstMessage"])
    end

    def compare_subset(area, actual, wanted)
      actual ||= {}
      wanted.each do |key, value|
        error(area, "#{key} is #{actual[key].inspect}, expected #{value.inspect}") if actual[key] != value
      end
    end

    # --- webhook ---

    def check_server
      server = @assistant["server"] || {}
      url = server["url"].to_s
      if url.blank?
        error("webhook", "no server URL is set: Vapi has nowhere to send tool calls")
      else
        uri = URI.parse(url) rescue nil
        if uri.nil? || uri.host.blank?
          error("webhook", "server URL is not a valid URL")
        else
          error("webhook", "server URL path is #{uri.path.inspect}, expected #{VapiConfig::WEBHOOK_PATH}") if uri.path.chomp("/") != VapiConfig::WEBHOOK_PATH
          error("webhook", "server URL must use https") if uri.scheme != "https"
          error("webhook", "server URL host is #{uri.host}, expected #{@expected_host}") if @expected_host.present? && uri.host != @expected_host
        end
      end
      check_secret(server)
      warn("webhook", "timeoutSeconds is #{server['timeoutSeconds'].inspect}; tools should answer well inside it") if server["timeoutSeconds"].to_i > 30
    end

    # Reports only: configured / mismatch / missing / unverifiable. The values are compared and never shown.
    def check_secret(server)
      sent = (server["headers"] || {}).find { |k, _| k.to_s.casecmp?(VapiConfig::SECRET_HEADER) }&.last
      if @webhook_secret.nil?
        error("webhook secret", "Rails has no usable VAPI_SERVER_SECRET (unset or under #{VapiConfig::MIN_SECRET_LENGTH} characters): every webhook would be refused")
      end
      if sent.blank?
        error("webhook secret", "missing: Vapi sends no #{VapiConfig::SECRET_HEADER} header")
      elsif sent.to_s.match?(/\A<?redacted>?\z|\A\*+\z/i)
        warn("webhook secret", "unverifiable: the Vapi API did not return the value; compare it by hand")
      elsif @webhook_secret && !ActiveSupport::SecurityUtils.secure_compare(sent.to_s, @webhook_secret)
        error("webhook secret", "mismatch: Vapi's #{VapiConfig::SECRET_HEADER} differs from Rails' VAPI_SERVER_SECRET")
      end
    end

    # --- helpers ---

    def normalize(text) = text.to_s.gsub(/\s+/, " ").strip
    def normalized_lines(text) = text.to_s.lines.map { |l| normalize(l) }.reject(&:empty?)
  end
end

namespace :vapi do
  desc "Read-only drift check: compare the development Vapi assistant with config/vapi, the system prompt and the Rails contract"
  task check: :environment do
    id = VapiConfig.dev_assistant_id
    abort "vapi:check: refusing to check the frozen baseline assistant; set VAPI_DEV_ASSISTANT_ID to the development assistant" if id == VapiConfig::BASELINE_ASSISTANT_ID

    begin
      assistant, tools = VapiConfig::Client.new.assistant_with_tools(id)
    rescue VapiConfig::Client::Error => e
      abort "vapi:check: cannot inspect Vapi - #{e.message}"
    end

    report = VapiConfig::DriftCheck.new(assistant: assistant, tools: tools, webhook_secret: VapiConfig.webhook_secret,
                                        expected_host: ENV["VAPI_EXPECTED_HOST"].presence).call
    puts "vapi:check  assistant #{assistant['name'].inspect} (#{id.to_s[0, 8]}…)  #{tools.size} tools"
    report.errors.each { |f| puts "  DRIFT  #{f.area}: #{f.message}" }
    report.warnings.each { |f| puts "  warn   #{f.area}: #{f.message}" }
    if report.clean?
      puts "  OK: tools, prompt, events, limits and webhook match the repository (webhook secret: #{report.warnings.any? { |f| f.area == 'webhook secret' } ? 'not verifiable' : 'configured, matches'})"
    else
      abort "vapi:check: #{report.errors.size} difference(s). Fix the Vapi assistant by hand (the repository is the source of truth), then re-run."
    end
  end
end

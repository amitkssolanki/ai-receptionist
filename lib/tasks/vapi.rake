namespace :vapi do
  desc "Read-only drift check: compare a Vapi assistant with config/vapi, the system prompt and the Rails contract " \
       "(PROFILE=development, the default, or PROFILE=fault_injection)"
  task check: :environment do
    begin
      profile = VapiConfig.profile(ENV.fetch("PROFILE", "development"))
    rescue ArgumentError => e
      abort "vapi:check: #{e.message}"
    end
    id = profile.assistant_id
    if id.blank?
      source = profile.fault_injection? ? "VAPI_FAULT_INJECTION_ASSISTANT_ID or credentials vapi.fault_injection_assistant_id" : "VAPI_DEV_ASSISTANT_ID or credentials vapi.dev_assistant_id"
      abort "vapi:check: no #{profile.key} assistant id is configured (#{source})"
    end
    abort "vapi:check: refusing to check the frozen baseline assistant; set VAPI_DEV_ASSISTANT_ID to the development assistant" if id == VapiConfig::BASELINE_ASSISTANT_ID

    begin
      assistant, tools = VapiConfig::Client.new.assistant_with_tools(id)
    rescue VapiConfig::Client::Error => e
      abort "vapi:check: cannot inspect Vapi - #{e.message}"
    end

    report = VapiConfig::DriftCheck.new(assistant: assistant, tools: tools, webhook_secret: VapiConfig.webhook_secret,
                                        expected_host: ENV["VAPI_EXPECTED_HOST"].presence, profile: profile).call
    label = profile.fault_injection? ? "  [FAULT INJECTION profile]" : ""
    puts "vapi:check#{label}  assistant #{assistant['name'].inspect} (#{id.to_s[0, 8]}…)  #{tools.size} tools"
    report.errors.each { |f| puts "  DRIFT  #{f.area}: #{f.message}" }
    report.warnings.each { |f| puts "  warn   #{f.area}: #{f.message}" }
    if report.clean?
      puts "  OK: tools, prompt, events, limits and webhook match the repository (webhook secret: #{report.warnings.any? { |f| f.area == 'webhook secret' } ? 'not verifiable' : 'configured, matches'})"
    else
      abort "vapi:check: #{report.errors.size} difference(s). Fix the Vapi assistant by hand (the repository is the source of truth), then re-run."
    end
  end
end

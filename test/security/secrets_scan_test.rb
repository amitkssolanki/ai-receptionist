require "test_helper"

# Repository hygiene checks (Phase 1 Step 10): no committed default webhook secret and no credential-shaped strings
# in tracked files, and the production config keeps TLS on. Patterns, never values, appear in failure messages.
class SecretsScanTest < ActiveSupport::TestCase
  # Frozen Phase 0 evidence and the execution log/plan describe the old behaviour by name; they are history.
  SKIPPED = %r{\A(test/fixtures/files/baseline/|docs/phase1/|test/security/|test/controllers/api/vapi/webhook_security_test\.rb|test/baseline/)}

  FORBIDDEN = {
    "the old default webhook secret" => Regexp.new(%w[dev secret change me].join("-")),
    "a Twilio account SID" => /\bAC[0-9a-f]{32}\b/,
    "a private key block" => /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    "an sk- style API key" => /\bsk-[A-Za-z0-9]{20,}\b/,
    "a GitHub token" => /\bgh[pousr]_[A-Za-z0-9]{30,}\b/,
    "an AWS access key id" => /\bAKIA[0-9A-Z]{16}\b/,
    "a hard-coded secret assignment" => /\b(?:secret|token|api_?key|password)\s*[:=]\s*["'][A-Za-z0-9+\/_\-]{20,}["']/i
  }.freeze

  def tracked_text_files
    files = `git -C #{Rails.root} ls-files`.split("\n").reject { |f| f.match?(SKIPPED) }
    files.select { |f| Rails.root.join(f).file? && !f.match?(/\.(png|jpe?g|gif|ico|svg|woff2?|enc|key)\z/) }
  end

  test "no tracked file contains a committed default secret or credential-shaped string" do
    skip "not a git checkout" if tracked_text_files.empty?

    offenders = tracked_text_files.flat_map do |file|
      text = Rails.root.join(file).read(encoding: "UTF-8", invalid: :replace, undef: :replace) rescue next
      FORBIDDEN.filter_map { |name, pattern| "#{file}: #{name}" if text.match?(pattern) }
    end.compact
    assert_empty offenders
  end

  test "the webhook controller has no fallback secret" do
    source = Rails.root.join("app/controllers/api/vapi/webhooks_controller.rb").read
    assert_no_match(/ENV\["VAPI_SERVER_SECRET"\]\.presence \|\| \(/, source)
    assert_no_match(/SecureRandom/, source)
  end

  test "credentials and keys are not tracked" do
    tracked = `git -C #{Rails.root} ls-files`.split("\n")
    assert_empty tracked.grep(%r{\Aconfig/(master|.*\.key)\z|\A\.env})
  end

  test "production forces TLS (health check excluded) and trusts the proxy" do
    production = Rails.root.join("config/environments/production.rb").read
    assert_match(/^\s*config\.assume_ssl = true/, production)
    assert_match(/^\s*config\.force_ssl = true/, production)
    assert_match(%r{^\s*config\.ssl_options = .*"/up"}, production)
  end

  test "request parameter filtering covers the webhook body and credentials" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    %w[message artifact transcript customer phoneNumber monitor transport secret token password].each do |key|
      assert_equal "[FILTERED]", filter.filter(key => "value")[key], key
    end
  end
end

require "test_helper"

# The committed production deployment configuration (config/deploy.yml, .kamal/secrets, config/vapi/production.json).
# It must name one hostname consistently, take every secret from the deploying machine's git-ignored .env.kamal, carry no
# secret value, and leave out what production must never have: the Rails master key, the Vapi private key, the
# fault-injection assistant and Twilio. docs/deploy/PRODUCTION.md is the runbook.
class ProductionConfigTest < ActiveSupport::TestCase
  HOST = "restaurant-receptionist.railsfanatics.com".freeze
  NEVER_IN_PRODUCTION = %w[RAILS_MASTER_KEY VAPI_PRIVATE_KEY VAPI_FAULT_INJECTION_ASSISTANT_ID VAPI_DEV_ASSISTANT_ID
                           TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_FROM_NUMBER DATABASE_URL].freeze

  def deploy = @deploy ||= YAML.load_file(Rails.root.join("config/deploy.yml"))
  def secret_lines = Rails.root.join(".kamal/secrets").readlines(chomp: true).grep_v(/\A\s*(#|\z)/)
  def secrets_file = secret_lines.to_h { |line| line.split("=", 2) }

  def every_secret_name
    [ *deploy.dig("env", "secret"), *deploy.dig("registry", "password"),
      *deploy["accessories"].values.flat_map { |a| Array(a.dig("env", "secret")) } ]
  end

  test "one production hostname: proxy, TLS, Rails host and the Vapi webhook URL agree" do
    assert_equal HOST, deploy.dig("proxy", "host")
    assert_equal true, deploy.dig("proxy", "ssl")
    assert_equal "/up", deploy.dig("proxy", "healthcheck", "path")
    assert_equal HOST, deploy.dig("env", "clear", "RAILS_HOST")

    production_assistant = JSON.parse(Rails.root.join("config/vapi/production.json").read)
    assert_equal "https://#{HOST}#{VapiConfig::WEBHOOK_PATH}", production_assistant["serverUrl"]
    assert_equal [ "https://#{HOST}" ], production_assistant["publicKeyAllowedOrigins"]
    assert_not_equal VapiConfig.settings["name"], production_assistant["name"]
    assert_not_equal VapiConfig.fault_injection_overrides["name"], production_assistant["name"]
  end

  test "the database is this application's own Postgres accessory" do
    postgres = deploy.dig("accessories", "postgres")
    assert_equal "#{deploy['service']}-postgres", deploy.dig("env", "clear", "DB_HOST")
    assert_equal "ai_receptionist", postgres.dig("env", "clear", "POSTGRES_USER")
    assert_equal "ai_receptionist_production", postgres.dig("env", "clear", "POSTGRES_DB")
    assert_nil postgres["port"], "the Postgres port must not be published on the shared host"

    database = YAML.load(ERB.new(Rails.root.join("config/database.yml").read).result, aliases: true)
    assert_equal "ai_receptionist_production", database.dig("production", "primary", "database")
    assert_equal "ai_receptionist", database.dig("production", "primary", "username")
  end

  test "with the deployed environment, each database pool is big enough for Solid Queue inside Puma" do
    env = deploy.dig("env", "clear").transform_values(&:to_s)
    erb = ->(path) { YAML.load(ERB.new(Rails.root.join(path).read).result_with_hash({}), aliases: true) }
    pool = with_env(env.merge("RAILS_MAX_THREADS" => env["RAILS_MAX_THREADS"])) do
      erb.("config/database.yml").dig("production", "primary", "max_connections").to_i
    end
    worker_threads = with_env(env) { erb.("config/queue.yml").dig("production", "workers").map { |w| w["threads"].to_i }.max }

    assert_equal "true", env["SOLID_QUEUE_IN_PUMA"]
    assert_operator pool, :>=, worker_threads + 2, "Solid Queue needs a pool of its worker threads + 2 (solid_queue configuration check)"
    assert_operator pool, :>=, Integer(env.fetch("RAILS_MAX_THREADS", 3)), "every Puma thread needs a connection"
  end

  def with_env(vars)
    before = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    yield
  ensure
    before.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  test "every secret deploy.yml needs comes from .kamal/secrets, and nothing production must not have is configured" do
    every_secret_name.each { |name| assert secrets_file.key?(name), "#{name} is used in config/deploy.yml but missing from .kamal/secrets" }

    configured = [ *deploy.dig("env", "clear")&.keys, *every_secret_name, *secrets_file.keys ]
    (NEVER_IN_PRODUCTION & configured).each { |name| flunk "#{name} must not be configured for production" }
    %w[SECRET_KEY_BASE VAPI_SERVER_SECRET VAPI_PUBLIC_KEY VAPI_ASSISTANT_ID ADMIN_EMAIL ADMIN_PASSWORD
       AI_RECEPTIONIST_DATABASE_PASSWORD].each { |name| assert_includes deploy.dig("env", "secret"), name }
  end

  test ".kamal/secrets holds no values: each line reads .env.kamal or refers to another secret" do
    secrets_file.each do |name, source|
      assert_match(/\A(\$\(grep '\^#{name}=' \.env\.kamal \| cut -d '=' -f2-\)|\$\{[A-Z_]+\})\z/, source,
                   "#{name} in .kamal/secrets must read .env.kamal, not hold a value")
    end
    assert_includes Rails.root.join(".gitignore").read, "/.env*"
    assert_includes Rails.root.join(".dockerignore").read, "/.env*"
  end
end

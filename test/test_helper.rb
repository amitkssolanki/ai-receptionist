ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Tests never see the developer's real Vapi credentials (private key, public key, dev assistant id, webhook secret). The
# encrypted credentials now hold them for local use, and a test that expects "no secret configured" must not depend on
# whoever runs it. Tests that need a value set the ENV var or stub credentials explicitly. In-memory only: the file is untouched.
Rails.application.credentials.then do |credentials|
  credentials.config.delete(:vapi)
  credentials.instance_variable_set(:@options, nil) # rebuilt lazily from config
end

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
  end
end

# Business hours that never close (the order rules refuse orders when the restaurant is closed).
ALWAYS_OPEN_HOURS = %w[sun mon tue wed thu fri sat].index_with { "24h" }.freeze

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
end

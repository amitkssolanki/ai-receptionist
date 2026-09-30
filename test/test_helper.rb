ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

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

require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module AiReceptionist
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # A job enqueued inside a tool call's transaction (the order-confirmation SMS) must not run if that transaction
    # rolls back: enqueue it only once the transaction commits (Phase 1 / Step 7).
    config.active_job.enqueue_after_transaction_commit = true

    # R23: with no valid console token and no dialed-number match, a call may fall back to the sole restaurant only
    # where this is on (development and test). Off everywhere else: an unresolvable call is refused, never guessed.
    config.x.vapi.default_restaurant_fallback = false

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end

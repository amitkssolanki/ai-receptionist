require "test_helper"

# db/seeds.rb and the admin login. Locally the seed keeps the documented admin@example.com login. Anywhere else it never
# creates a known login: ADMIN_EMAIL and ADMIN_PASSWORD bootstrap the first admin of an empty database, and once any user
# exists they are ignored, so values left in the environment after the first deploy cannot add, recreate or change an
# account. bin/docker-entrypoint runs db:prepare, which seeds a fresh production database.
class AdminBootstrapTest < ActiveSupport::TestCase
  OWNER_EMAIL = "owner@example.com".freeze
  OWNER_PASSWORD = "a-long-test-password-0000".freeze # explicit test values, not credentials
  OTHER_PASSWORD = "another-long-test-password-1111".freeze

  # Runs db/seeds.rb as if in `env` (Rails.env is restored afterwards; each test process runs one test at a time).
  def seed_as(env, vars = {})
    env_before, vars_before = Rails.env, vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    Rails.env = env
    capture_io { load Rails.root.join("db/seeds.rb") }
  ensure
    Rails.env = env_before
    vars_before.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  def seed_production(email: OWNER_EMAIL, password: OWNER_PASSWORD)
    seed_as("production", "ADMIN_EMAIL" => email, "ADMIN_PASSWORD" => password)
  end

  def snapshot
    [ Restaurant, User, MenuCategory, MenuItem, MenuItemModifier, MenuItemUpsell ]
      .to_h { |model| [ model.name, model.order(:id).map(&:attributes) ] }
  end

  test "an empty production database gets no default admin without ADMIN_EMAIL and ADMIN_PASSWORD" do
    seed_production(email: nil, password: nil)
    assert_not User.exists?
  end

  test "a short ADMIN_PASSWORD is refused while bootstrapping" do
    assert_raises(ArgumentError) { seed_production(password: "short-password") }
    assert_not User.exists?
  end

  test "the first production seed creates exactly the configured admin" do
    seed_production
    assert_equal [ OWNER_EMAIL ], User.pluck(:email)
    assert User.find_by(email: OWNER_EMAIL).valid_password?(OWNER_PASSWORD)
  end

  test "seeding production again is a no-op, with the variables still set" do
    seed_production
    before = snapshot
    seed_production
    seed_production
    assert_equal before, snapshot
  end

  test "a different ADMIN_PASSWORD left in the environment never resets the existing admin" do
    seed_production
    admin = User.find_by(email: OWNER_EMAIL)
    seed_production(password: OTHER_PASSWORD)
    assert_equal admin.attributes, admin.reload.attributes
    assert admin.valid_password?(OWNER_PASSWORD)
    assert_not admin.valid_password?(OTHER_PASSWORD)
  end

  test "after the admin changes their email, the old ADMIN_EMAIL does not recreate an account" do
    seed_production
    User.find_by(email: OWNER_EMAIL).update!(email: "renamed-owner@example.com")
    seed_production
    assert_equal [ "renamed-owner@example.com" ], User.pluck(:email)
  end

  test "a new ADMIN_EMAIL does not add a second admin once one exists" do
    seed_production
    seed_production(email: "second-owner@example.com", password: OTHER_PASSWORD)
    assert_equal [ OWNER_EMAIL ], User.pluck(:email)
  end

  test "a short leftover ADMIN_PASSWORD does not break seeding once an admin exists" do
    seed_production
    assert_nothing_raised { seed_production(password: "short-password") }
  end

  test "development seeds keep the documented local login" do
    seed_as("development")
    assert User.find_by(email: "admin@example.com").valid_password?("password123")
  end
end

# Devise's sessions controller plus a brake on password guessing: 10 sign-in attempts per 3 minutes per client IP.
class Users::SessionsController < Devise::SessionsController
  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { redirect_to new_user_session_path, alert: "Too many sign-in attempts. Try again in a few minutes." }
end

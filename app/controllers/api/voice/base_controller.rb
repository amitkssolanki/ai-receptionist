class Api::Voice::BaseController < ActionController::API
  before_action :authenticate_webhook!

  rescue_from ActiveRecord::RecordNotFound do |e|
    render json: { error: e.message }, status: :not_found
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def authenticate_webhook!
    provided = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, expected_webhook_secret)
  end

  def expected_webhook_secret
    ENV["VOICE_WEBHOOK_SECRET"].presence || (Rails.env.production? ? SecureRandom.hex : "dev-secret-change-me")
  end
end

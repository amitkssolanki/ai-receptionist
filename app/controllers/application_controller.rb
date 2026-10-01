class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  # After sign-in: the page the admin was sent away from, else the dashboard (the root is the public homepage).
  def after_sign_in_path_for(resource) = stored_location_for(resource) || admin_root_path
end

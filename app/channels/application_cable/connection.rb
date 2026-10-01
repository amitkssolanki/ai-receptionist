module ApplicationCable
  # Only a signed-in admin (Devise/Warden session cookie) may open a cable connection at all.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = env["warden"]&.user || reject_unauthorized_connection
    end
  end
end

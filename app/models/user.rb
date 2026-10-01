class User < ApplicationRecord
  belongs_to :restaurant

  # Sign-in only. No :registerable (admins are seeded) and no :recoverable: an anonymous password-reset request would write
  # a reset token on the admin's row and send mail, and no mailer is configured. Reset a password with bin/rails runner.
  devise :database_authenticatable, :rememberable, :validatable
end

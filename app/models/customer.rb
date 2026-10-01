class Customer < ApplicationRecord
  belongs_to :restaurant
  has_many :orders, dependent: :restrict_with_error
  has_many :call_logs, dependent: :nullify

  validates :phone_number, presence: true, uniqueness: { scope: :restaurant_id }

  # E.164 (+ country code, 7-15 digits). Browser/web calls have no caller number, so their customers carry a
  # synthetic "unknown-<call id>" placeholder, which is never a texting destination.
  E164 = /\A\+[1-9]\d{6,14}\z/

  def sms_capable? = phone_number.to_s.match?(E164)
end

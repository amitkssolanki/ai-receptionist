class Customer < ApplicationRecord
  belongs_to :restaurant
  has_many :orders, dependent: :restrict_with_error
  has_many :call_logs, dependent: :nullify

  validates :phone_number, presence: true, uniqueness: { scope: :restaurant_id }
end

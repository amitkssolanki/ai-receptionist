class Order < ApplicationRecord
  belongs_to :restaurant
  belongs_to :customer
  has_many :order_items, dependent: :destroy
  has_one :call_log, dependent: :nullify

  enum :status, {
    pending: "pending",
    confirmed: "confirmed",
    preparing: "preparing",
    ready: "ready",
    completed: "completed",
    cancelled: "cancelled"
  }, default: :pending

  enum :fulfillment_type, { pickup: "pickup", delivery: "delivery" }

  validates :delivery_address, presence: true, if: :delivery?

  def total
    total_cents / 100.0
  end
end

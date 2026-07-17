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

  def recompute_total!
    update!(total_cents: order_items.sum(&:subtotal_cents))
  end

  def cart_summary
    {
      items: order_items.map do |item|
        {
          id: item.id,
          menu_item: item.menu_item.name,
          quantity: item.quantity,
          modifiers: item.selected_modifiers,
          subtotal: item.subtotal_cents / 100.0
        }
      end,
      total: total_cents / 100.0
    }
  end
end

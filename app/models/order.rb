class Order < ApplicationRecord
  belongs_to :restaurant
  belongs_to :customer
  has_many :order_items, dependent: :destroy
  has_one :call_log, dependent: :nullify
  has_many :tool_invocations, dependent: :nullify

  enum :status, {
    pending: "pending",
    confirmed: "confirmed",
    preparing: "preparing",
    ready: "ready",
    completed: "completed",
    cancelled: "cancelled",
    abandoned: "abandoned"
  }, default: :pending

  # Orders only move forward. Nothing returns to pending (the cart is closed once submitted) and
  # completed/cancelled/abandoned are final.
  TRANSITIONS = {
    "pending" => %w[confirmed cancelled abandoned],
    "confirmed" => %w[preparing ready completed cancelled],
    "preparing" => %w[ready completed cancelled],
    "ready" => %w[completed cancelled],
    "completed" => [],
    "cancelled" => [],
    "abandoned" => []
  }.freeze

  enum :fulfillment_type, { pickup: "pickup", delivery: "delivery" }

  validates :delivery_address, presence: true, if: :delivery?
  validate :status_transition_allowed, on: :update, if: :status_changed?

  # The cart can change only while the order is still pending.
  def cart_open? = pending?

  def allowed_next_statuses = TRANSITIONS.fetch(status, [])

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

  private

  def status_transition_allowed
    return if TRANSITIONS.fetch(status_was, []).include?(status)

    errors.add(:status, "can't change from #{status_was.humanize.downcase} to #{status.humanize.downcase}")
  end
end

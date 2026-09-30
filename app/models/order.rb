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

  # Placed by the caller: anything past pending that wasn't merely an abandoned cart.
  def submitted? = !pending? && !abandoned?

  def allowed_next_statuses = TRANSITIONS.fetch(status, [])

  def total
    total_cents / 100.0
  end

  # bump_version: true marks an authoritative cart change (add / change / remove); read-backs are tied to it.
  def recompute_total!(bump_version: false)
    attrs = { total_cents: order_items.sum(&:subtotal_cents) }
    attrs[:cart_version] = cart_version + 1 if bump_version
    update!(attrs)
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
      total: total_cents / 100.0,
      cart_version: cart_version
    }
  end

  private

  def status_transition_allowed
    return if TRANSITIONS.fetch(status_was, []).include?(status)

    errors.add(:status, "can't change from #{status_was.humanize.downcase} to #{status.humanize.downcase}")
  end
end

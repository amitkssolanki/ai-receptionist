class MenuItem < ApplicationRecord
  belongs_to :restaurant
  belongs_to :menu_category
  has_many :menu_item_modifiers, -> { order(:position) }, dependent: :destroy
  has_many :order_items, dependent: :restrict_with_error

  validates :name, presence: true
  validates :price_cents, numericality: { greater_than_or_equal_to: 0 }

  scope :available, -> { where(available: true) }

  def price
    price_cents / 100.0
  end

  def price=(value)
    self.price_cents = (value.to_f * 100).round
  end
end

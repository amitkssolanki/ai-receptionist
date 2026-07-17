class MenuItemModifier < ApplicationRecord
  belongs_to :menu_item

  validates :name, presence: true
  validates :price_cents, numericality: true
end

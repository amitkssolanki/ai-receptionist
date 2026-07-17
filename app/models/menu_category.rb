class MenuCategory < ApplicationRecord
  belongs_to :restaurant
  has_many :menu_items, -> { order(:position) }, dependent: :destroy

  validates :name, presence: true
end

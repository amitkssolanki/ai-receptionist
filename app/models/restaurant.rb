class Restaurant < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :menu_categories, -> { order(:position) }, dependent: :destroy
  has_many :menu_items, dependent: :destroy
  has_many :customers, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :call_logs, dependent: :destroy

  validates :name, presence: true
  validates :phone_number, presence: true
  validates :timezone, presence: true
end

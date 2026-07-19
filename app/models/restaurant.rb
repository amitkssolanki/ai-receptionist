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

  DAY_KEYS = %w[sun mon tue wed thu fri sat].freeze

  # business_hours format: {"mon" => "11:00-21:00", ..., "sun" => "closed"}. Does not
  # support hours that cross midnight.
  def hours_today(at: Time.current)
    business_hours[DAY_KEYS[at.in_time_zone(timezone).wday]]
  end

  def open_now?(at: Time.current)
    hours = hours_today(at: at)
    return false if hours.blank? || hours == "closed"

    local_time = at.in_time_zone(timezone)
    open_str, close_str = hours.split("-")
    local_time.between?(time_on(local_time, open_str), time_on(local_time, close_str))
  end

  private

  def time_on(local_time, time_str)
    hour, minute = time_str.split(":").map(&:to_i)
    local_time.change(hour: hour, min: minute)
  end
end

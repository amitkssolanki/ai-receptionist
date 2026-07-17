class CallLog < ApplicationRecord
  belongs_to :restaurant
  belongs_to :customer, optional: true
  belongs_to :order, optional: true

  enum :status, {
    in_progress: "in_progress",
    completed: "completed",
    transferred: "transferred",
    abandoned: "abandoned"
  }, default: :in_progress

  validates :external_call_id, presence: true, uniqueness: true
  validates :phone_number, presence: true
end

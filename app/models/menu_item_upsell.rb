class MenuItemUpsell < ApplicationRecord
  belongs_to :menu_item
  belongs_to :upsell_item, class_name: "MenuItem"

  validates :upsell_item_id, uniqueness: { scope: :menu_item_id }
  validate :cannot_upsell_self

  private

  def cannot_upsell_self
    errors.add(:upsell_item, "can't be the same as the menu item") if menu_item_id == upsell_item_id
  end
end

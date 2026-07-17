class Admin::MenuItemModifiersController < Admin::BaseController
  before_action :set_menu_item, only: [ :new, :create ]
  before_action :set_menu_item_modifier, only: [ :edit, :update, :destroy ]

  def new
    @menu_item_modifier = @menu_item.menu_item_modifiers.build
  end

  def create
    @menu_item_modifier = @menu_item.menu_item_modifiers.build(menu_item_modifier_params)

    if @menu_item_modifier.save
      redirect_to admin_menu_item_path(@menu_item), notice: "Modifier added."
    else
      redirect_to admin_menu_item_path(@menu_item), alert: @menu_item_modifier.errors.full_messages.to_sentence
    end
  end

  def edit
  end

  def update
    if @menu_item_modifier.update(menu_item_modifier_params)
      redirect_to admin_menu_item_path(@menu_item), notice: "Modifier updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    menu_item = @menu_item_modifier.menu_item
    @menu_item_modifier.destroy
    redirect_to admin_menu_item_path(menu_item), notice: "Modifier removed."
  end

  private

  def set_menu_item
    @menu_item = current_restaurant.menu_items.find(params[:menu_item_id])
  end

  def set_menu_item_modifier
    @menu_item_modifier = MenuItemModifier.joins(:menu_item)
                                           .where(menu_items: { restaurant_id: current_restaurant.id })
                                           .find(params[:id])
    @menu_item = @menu_item_modifier.menu_item
  end

  def menu_item_modifier_params
    params.expect(menu_item_modifier: [ :name, :price_cents, :position ])
  end
end

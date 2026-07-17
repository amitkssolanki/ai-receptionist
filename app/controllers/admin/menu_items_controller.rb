class Admin::MenuItemsController < Admin::BaseController
  before_action :set_menu_category, only: [ :index, :new, :create ]
  before_action :set_menu_item, only: [ :show, :edit, :update, :destroy ]

  def index
    @menu_items = @menu_category.menu_items
  end

  def show
  end

  def new
    @menu_item = @menu_category.menu_items.build
  end

  def create
    @menu_item = @menu_category.menu_items.build(menu_item_params.merge(restaurant: current_restaurant))

    if @menu_item.save
      redirect_to admin_menu_category_menu_items_path(@menu_category), notice: "Menu item created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @menu_item.update(menu_item_params)
      redirect_to admin_menu_item_path(@menu_item), notice: "Menu item updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @menu_item.destroy
    redirect_to admin_menu_category_menu_items_path(@menu_item.menu_category), notice: "Menu item deleted."
  end

  private

  def set_menu_category
    @menu_category = current_restaurant.menu_categories.find(params[:menu_category_id])
  end

  def set_menu_item
    @menu_item = current_restaurant.menu_items.find(params[:id])
  end

  def menu_item_params
    params.expect(menu_item: [ :name, :description, :price, :available, :position ])
  end
end

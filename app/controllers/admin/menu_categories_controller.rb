class Admin::MenuCategoriesController < Admin::BaseController
  before_action :set_menu_category, only: [ :show, :edit, :update, :destroy ]

  def index
    @menu_categories = current_restaurant.menu_categories
  end

  def show
  end

  def new
    @menu_category = current_restaurant.menu_categories.build
  end

  def create
    @menu_category = current_restaurant.menu_categories.build(menu_category_params)

    if @menu_category.save
      redirect_to admin_menu_categories_path, notice: "Menu category created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @menu_category.update(menu_category_params)
      redirect_to admin_menu_categories_path, notice: "Menu category updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @menu_category.destroy
    redirect_to admin_menu_categories_path, notice: "Menu category deleted."
  end

  private

  def set_menu_category
    @menu_category = current_restaurant.menu_categories.find(params[:id])
  end

  def menu_category_params
    params.expect(menu_category: [ :name, :position ])
  end
end

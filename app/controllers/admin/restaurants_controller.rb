class Admin::RestaurantsController < Admin::BaseController
  def edit
    @restaurant = current_restaurant
  end

  def update
    if current_restaurant.update(restaurant_params)
      redirect_to edit_admin_restaurant_path, notice: "Settings updated."
    else
      @restaurant = current_restaurant
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def restaurant_params
    params.expect(restaurant: [ :name, :phone_number, :address, :timezone,
                               business_hours: [ :mon, :tue, :wed, :thu, :fri, :sat, :sun ] ])
  end
end

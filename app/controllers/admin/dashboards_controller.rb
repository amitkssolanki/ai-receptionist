class Admin::DashboardsController < Admin::BaseController
  def show
    @restaurant = current_restaurant
    @recent_orders = current_restaurant.orders.order(created_at: :desc).limit(10)
    @recent_calls = current_restaurant.call_logs.order(started_at: :desc).limit(10)
  end
end

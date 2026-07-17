class Admin::OrdersController < Admin::BaseController
  before_action :set_order, only: [ :show, :update ]

  def index
    @orders = current_restaurant.orders.order(created_at: :desc)
  end

  def show
  end

  def update
    if @order.update(status: params.expect(order: [ :status ])[:status])
      redirect_to admin_order_path(@order), notice: "Order status updated."
    else
      redirect_to admin_order_path(@order), alert: @order.errors.full_messages.to_sentence
    end
  end

  private

  def set_order
    @order = current_restaurant.orders.find(params[:id])
  end
end

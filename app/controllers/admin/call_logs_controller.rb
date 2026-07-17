class Admin::CallLogsController < Admin::BaseController
  def index
    @call_logs = current_restaurant.call_logs.order(started_at: :desc)
  end

  def show
    @call_log = current_restaurant.call_logs.find(params[:id])
  end
end

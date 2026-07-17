class Admin::BaseController < ApplicationController
  before_action :authenticate_user!

  private

  def current_restaurant
    current_user.restaurant
  end
end

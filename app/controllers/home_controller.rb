# The public homepage. Static: it reads no records and no configuration values, so nothing private can reach it
# (test/controllers/home_controller_test.rb). Everything it links to beyond sign-in still requires a signed-in admin.
class HomeController < ApplicationController
  layout "home"

  def show
  end
end

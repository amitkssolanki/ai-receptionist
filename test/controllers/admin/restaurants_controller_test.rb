require "test_helper"

class Admin::RestaurantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @restaurant = Restaurant.create!(
      name: "Test Bistro", phone_number: "+15550005555", timezone: "America/New_York",
      business_hours: { "mon" => "11:00-21:00", "sun" => "closed" }
    )
    @user = User.create!(email: "owner@example.com", password: "password123", restaurant: @restaurant)
  end

  test "requires authentication" do
    get edit_admin_restaurant_path
    assert_redirected_to new_user_session_path
  end

  test "renders current settings" do
    sign_in @user
    get edit_admin_restaurant_path
    assert_response :success
    assert_match @restaurant.phone_number, response.body
    assert_match "11:00-21:00", response.body
  end

  test "updates restaurant details and business hours" do
    sign_in @user

    patch admin_restaurant_path, params: {
      restaurant: {
        name: "Updated Bistro",
        phone_number: "+15559990000",
        address: "456 New St",
        timezone: "America/Chicago",
        business_hours: {
          mon: "10:00-20:00", tue: "10:00-20:00", wed: "closed",
          thu: "closed", fri: "closed", sat: "closed", sun: "closed"
        }
      }
    }
    assert_redirected_to edit_admin_restaurant_path

    @restaurant.reload
    assert_equal "Updated Bistro", @restaurant.name
    assert_equal "+15559990000", @restaurant.phone_number
    assert_equal "America/Chicago", @restaurant.timezone
    assert_equal "10:00-20:00", @restaurant.business_hours["mon"]
    assert_equal "closed", @restaurant.business_hours["wed"]
  end

  test "rejects invalid updates" do
    sign_in @user

    patch admin_restaurant_path, params: { restaurant: { name: "", business_hours: {} } }
    assert_response :unprocessable_entity

    @restaurant.reload
    assert_equal "Test Bistro", @restaurant.name
  end
end

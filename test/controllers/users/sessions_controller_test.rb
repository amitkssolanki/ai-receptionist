require "test_helper"

class Users::SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    restaurant = Restaurant.create!(name: "Login Bistro", phone_number: "+15550003131")
    @user = User.create!(email: "login@example.com", password: "password123", restaurant: restaurant)
  end

  teardown { Rails.cache.clear }

  test "sign-in still works" do
    post user_session_path, params: { user: { email: @user.email, password: "password123" } }
    assert_redirected_to admin_root_path
  end

  test "the 11th sign-in attempt within three minutes is refused, even with the right password" do
    10.times do
      post user_session_path, params: { user: { email: @user.email, password: "wrong-password" } }
      assert_response :unprocessable_entity
    end

    post user_session_path, params: { user: { email: @user.email, password: "password123" } }
    assert_redirected_to new_user_session_path
    assert_match(/Too many sign-in attempts/, flash[:alert])
    get admin_root_path
    assert_redirected_to new_user_session_path, "the refused attempt did not sign anyone in"
  end

  test "the limit lifts after the window" do
    10.times { post user_session_path, params: { user: { email: @user.email, password: "wrong-password" } } }
    travel 4.minutes do
      post user_session_path, params: { user: { email: @user.email, password: "password123" } }
      assert_redirected_to admin_root_path
    end
  end

  test "signing in after being sent away from a protected page returns there, not to the public homepage" do
    get admin_console_path
    assert_redirected_to new_user_session_path
    post user_session_path, params: { user: { email: @user.email, password: "password123" } }
    assert_redirected_to admin_console_path
  end

  test "signing out returns to the public homepage" do
    post user_session_path, params: { user: { email: @user.email, password: "password123" } }
    delete destroy_user_session_path
    assert_redirected_to root_path
    get admin_root_path
    assert_redirected_to new_user_session_path
  end

  test "the login page renders through the subclass" do
    get new_user_session_path
    assert_response :success
  end
end

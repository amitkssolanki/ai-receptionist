require "test_helper"

class RestaurantTest < ActiveSupport::TestCase
  setup do
    @restaurant = Restaurant.create!(
      name: "Test Bistro",
      phone_number: "+15550003333",
      timezone: "America/New_York",
      business_hours: { "mon" => "11:00-21:00", "sun" => "closed" }
    )
  end

  test "open_now? is true within today's hours" do
    monday_noon = ActiveSupport::TimeZone["America/New_York"].local(2024, 1, 1, 12, 0)
    travel_to monday_noon do
      assert @restaurant.open_now?
      assert_equal "11:00-21:00", @restaurant.hours_today
    end
  end

  test "open_now? is false before opening and after closing" do
    before_open = ActiveSupport::TimeZone["America/New_York"].local(2024, 1, 1, 9, 0)
    after_close = ActiveSupport::TimeZone["America/New_York"].local(2024, 1, 1, 22, 0)

    travel_to before_open do
      assert_not @restaurant.open_now?
    end

    travel_to after_close do
      assert_not @restaurant.open_now?
    end
  end

  test "open_now? is false on a day marked closed" do
    sunday = ActiveSupport::TimeZone["America/New_York"].local(2024, 1, 7, 12, 0)
    travel_to sunday do
      assert_not @restaurant.open_now?
      assert_equal "closed", @restaurant.hours_today
    end
  end
end

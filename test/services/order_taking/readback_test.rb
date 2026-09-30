require "test_helper"

class OrderTaking::ReadbackTest < ActiveSupport::TestCase
  test "words covers units, teens, tens, hundreds and thousands" do
    {
      0 => "zero", 1 => "one", 13 => "thirteen", 20 => "twenty", 21 => "twenty-one", 30 => "thirty", 99 => "ninety-nine",
      100 => "one hundred", 101 => "one hundred one", 250 => "two hundred fifty", 1000 => "one thousand",
      7000 => "seven thousand", 7250 => "seven thousand two hundred fifty", 999_999 => "nine hundred ninety-nine thousand nine hundred ninety-nine"
    }.each { |n, text| assert_equal text, OrderTaking::Readback.words(n), n }
  end

  test "money speaks dollars and cents with correct plurals" do
    assert_equal "zero dollars", OrderTaking::Readback.money(0)
    assert_equal "one dollar", OrderTaking::Readback.money(100)
    assert_equal "sixteen dollars", OrderTaking::Readback.money(1600)
    assert_equal "twenty-one dollars and fifty cents", OrderTaking::Readback.money(2150)
    assert_equal "five dollars and one cent", OrderTaking::Readback.money(501)
  end

  test "modifier names are lower-cased except acronyms" do
    assert_equal "extra cheese", OrderTaking::Readback.spoken("Extra cheese")
    assert_equal "BBQ sauce", OrderTaking::Readback.spoken("BBQ sauce")
  end
end

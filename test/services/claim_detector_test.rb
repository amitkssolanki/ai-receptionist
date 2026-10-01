require "test_helper"

class ClaimDetectorTest < ActiveSupport::TestCase
  test "assistant lines that claim an order change are recognised" do
    {
      "Great. I'll add garlic knots. One Margherita pizza with extra cheese, and one order of garlic knots." => "add",
      "I’ve added the fries for you." => "add",
      "I have added two sodas." => "add",
      "Adding that now." => "add",
      "I've removed the salad." => "remove",
      "I'll remove the onions." => "remove",
      "I've changed that to two." => "change",
      "I updated your order." => "change"
    }.each { |line, kind| assert_equal kind, ClaimDetector.kind(line), line }
  end

  test "questions, read-backs and small talk are not claims" do
    [ "Anything else, or should I read back your order?", "I've got one Margherita pizza with extra cheese for pickup, total $16.",
      "We have garlic knots and fries.", "Would you like me to add garlic knots?", "", nil, "Thanks for calling." ].each do |line|
      assert_nil ClaimDetector.kind(line), line.inspect
    end
  end

  test "the patterns given to the browser are the same list, as plain data" do
    assert_equal ClaimDetector::PATTERNS.keys, ClaimDetector.browser_patterns.map { |p| p[:kind] }
    ClaimDetector.browser_patterns.each { |p| assert_nothing_raised { Regexp.new(p[:source], Regexp::IGNORECASE) } }
  end

  test "the recorded garlic knots line, verbatim from call #7, is a claim" do
    timeline = JSON.parse(Rails.root.join("test/fixtures/files/baseline/call7/timeline.json").read)
    claim = timeline.find { |row| row["role"] == "bot" && row["message"].to_s.include?("I'll add garlic knots") }
    assert_equal "add", ClaimDetector.kind(claim["message"])
  end
end

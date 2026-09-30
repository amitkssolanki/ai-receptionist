require "test_helper"

class Voice::ToolArgumentsTest < ActiveSupport::TestCase
  def parse(tool, raw) = Voice::ToolArguments.parse(tool, raw)

  def assert_invalid(tool, raw, pattern)
    result = parse(tool, raw)
    assert_not_predicate result, :ok?, "expected #{raw.inspect} to be invalid for #{tool}"
    assert_match pattern, result.error
    assert_nil result.values
  end

  test "valid arguments come back symbol-keyed and typed" do
    result = parse("add_to_cart", { "menu_item_id" => 5, "quantity" => 2, "modifier_ids" => [ 6, 7 ], "notes" => "no onion" })
    assert_predicate result, :ok?
    assert_equal({ menu_item_id: 5, quantity: 2, modifier_ids: [ 6, 7 ], notes: "no onion" }, result.values)
  end

  test "JSON strings, symbol keys and blank strings are accepted where sensible" do
    assert_equal({ menu_item_id: 5 }, parse("add_to_cart", '{"menu_item_id": 5}').values)
    assert_equal({ menu_item_id: 5 }, parse("add_to_cart", { menu_item_id: 5 }).values)
    assert_equal({}, parse("get_cart", "").values)
    assert_equal({}, parse("get_cart", nil).values)
  end

  test "integer-looking strings and integral floats are coerced; fractions and words are not" do
    assert_equal 3, parse("add_to_cart", { "menu_item_id" => 1, "quantity" => "3" }).values[:quantity]
    assert_equal 3, parse("add_to_cart", { "menu_item_id" => 1, "quantity" => 3.0 }).values[:quantity]
    assert_invalid "add_to_cart", { "menu_item_id" => 1, "quantity" => 2.5 }, /quantity must be a whole number/
    assert_invalid "add_to_cart", { "menu_item_id" => 1, "quantity" => "two" }, /quantity must be a whole number \(got "two"\)/
    assert_invalid "add_to_cart", { "menu_item_id" => 1, "quantity" => true }, /quantity/
    assert_invalid "add_to_cart", { "menu_item_id" => 1, "quantity" => [ 1 ] }, /quantity/
  end

  test "missing and null required fields are named" do
    assert_invalid "add_to_cart", {}, /menu_item_id is required/
    assert_invalid "add_to_cart", { "menu_item_id" => nil }, /menu_item_id is required/
    assert_invalid "update_cart_item_quantity", { "order_item_id" => 1 }, /quantity is required/
    assert_invalid "remove_cart_item", {}, /order_item_id is required/
    assert_invalid "submit_order", {}, /fulfillment_type is required/
    assert_invalid "submit_order", { "fulfillment_type" => "pickup" }, /cart_version is required/
  end

  test "optional nulls are simply absent" do
    assert_equal({ menu_item_id: 1 }, parse("add_to_cart", { "menu_item_id" => 1, "quantity" => nil, "modifier_ids" => nil, "notes" => nil }).values)
  end

  test "lists must be lists of whole numbers" do
    assert_invalid "add_to_cart", { "menu_item_id" => 1, "modifier_ids" => 6 }, /modifier_ids must be a list/
    assert_invalid "add_to_cart", { "menu_item_id" => 1, "modifier_ids" => [ 6, "extra cheese" ] }, /modifier_ids must be a list/
    assert_equal [ 6 ], parse("add_to_cart", { "menu_item_id" => 1, "modifier_ids" => [ "6" ] }).values[:modifier_ids]
  end

  test "enum and text fields" do
    assert_equal "delivery", parse("submit_order", { "fulfillment_type" => "delivery", "cart_version" => 2 }).values[:fulfillment_type]
    assert_invalid "submit_order", { "fulfillment_type" => "teleport" }, /fulfillment_type must be one of: pickup, delivery/
    assert_invalid "submit_order", { "fulfillment_type" => "Pickup" }, /must be one of/
    assert_invalid "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1, "notes" => 5 }, /notes must be text/
    assert_invalid "transfer_to_human", { "reason" => { "why" => "x" } }, /reason must be text/
  end

  test "unknown fields are dropped, never forwarded (price injection)" do
    result = parse("add_to_cart", { "menu_item_id" => 1, "unit_price_cents" => 1, "price" => 0.01, "total" => 0 })
    assert_equal({ menu_item_id: 1 }, result.values)
  end

  test "malformed JSON and non-object arguments are refused, and kept as received" do
    bad = parse("add_to_cart", "{not json")
    assert_not_predicate bad, :ok?
    assert_match(/not valid JSON/, bad.error)
    assert_equal "{not json", bad.received

    [ "[1, 2]", "5", "\"text\"", [ 1, 2 ], 5 ].each { |raw| assert_invalid "add_to_cart", raw, /must be a JSON object/ }
  end

  test "error messages are short even for huge values" do
    result = parse("add_to_cart", { "menu_item_id" => 1, "quantity" => "x" * 5000 })
    assert_operator result.error.length, :<, 200
  end

  test "every tool the runner dispatches has a schema" do
    assert_equal %w[add_to_cart get_cart get_menu remove_cart_item submit_order transfer_to_human update_cart_item_quantity],
                 Voice::ToolArguments::SCHEMAS.keys.sort
    assert_not Voice::ToolArguments.known?("nope")
  end
end

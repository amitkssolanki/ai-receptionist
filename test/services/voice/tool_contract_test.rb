require "test_helper"

# config/vapi/tools.json is what gets pasted into Vapi. It must describe exactly what Voice::ToolArguments accepts.
class Voice::ToolContractTest < ActiveSupport::TestCase
  TOOLS = JSON.parse(Rails.root.join("config/vapi/tools.json").read).map { |t| t["function"] }.index_by { |f| f["name"] }

  test "tools.json and the argument schemas define the same tools" do
    assert_equal Voice::ToolArguments::SCHEMAS.keys.sort, TOOLS.keys.sort
  end

  test "parameter names, required lists, types and enums match" do
    Voice::ToolArguments::SCHEMAS.each do |name, schema|
      params = TOOLS.fetch(name)["parameters"]
      assert_equal schema.keys.map(&:to_s).sort, params["properties"].keys.sort, "#{name} parameters"
      assert_equal schema.select { |_, spec| spec[:required] }.keys.map(&:to_s).sort, params["required"].sort, "#{name} required"

      schema.each do |field, spec|
        declared = params["properties"].fetch(field.to_s)
        case spec[:type]
        when :integer then assert_equal "integer", declared["type"], "#{name}.#{field}"
        when :integer_list then assert_equal [ "array", "integer" ], [ declared["type"], declared.dig("items", "type") ], "#{name}.#{field}"
        when :string then assert_equal "string", declared["type"], "#{name}.#{field}"
        end
        if spec[:enum]
          assert_equal spec[:enum], declared["enum"], "#{name}.#{field} enum"
        else
          assert_nil declared["enum"], "#{name}.#{field} enum"
        end
      end
    end
  end

  test "every tool has a description the model can act on" do
    TOOLS.each_value { |f| assert_operator f["description"].length, :>, 40, f["name"] }
  end

  test "the runner dispatches exactly the declared tools" do
    source = Rails.root.join("app/services/voice/tool_runner.rb").read
    dispatched = source.scan(/when "([a-z_]+)"/).flatten
    assert_equal TOOLS.keys.sort, dispatched.sort
  end
end

# Typed, validated tool arguments: the only way model-supplied data reaches the business services.
#
# parse(tool_name, raw) takes whatever the provider sent (a Hash, a JSON string, nil) and returns either a
# symbol-keyed hash of correctly typed values for that tool, or one speakable error naming the field. Unknown
# fields are dropped (never forwarded), which is what keeps price/total injection out (R19).
module Voice
  class ToolArguments
    Result = Data.define(:values, :received, :error) do
      def ok? = error.nil?
    end

    INTEGER_PATTERN = /\A\s*-?\d+\s*\z/

    SCHEMAS = {
      "get_menu" => {},
      "get_cart" => {},
      "add_to_cart" => {
        menu_item_id: { type: :integer, required: true },
        quantity: { type: :integer },
        modifier_ids: { type: :integer_list },
        notes: { type: :string }
      },
      "update_cart_item_quantity" => {
        order_item_id: { type: :integer, required: true },
        quantity: { type: :integer, required: true }
      },
      "remove_cart_item" => {
        order_item_id: { type: :integer, required: true }
      },
      "submit_order" => {
        fulfillment_type: { type: :string, required: true, enum: %w[pickup delivery] },
        delivery_address: { type: :string },
        notes: { type: :string }
      },
      "transfer_to_human" => {
        reason: { type: :string }
      }
    }.freeze

    def self.known?(tool_name) = SCHEMAS.key?(tool_name)

    def self.parse(tool_name, raw) = new(tool_name, raw).parse

    def initialize(tool_name, raw)
      @schema = SCHEMAS.fetch(tool_name)
      @raw = raw
    end

    def parse
      received = decode
      return failure(@raw, "The arguments were not valid JSON. Send them as a JSON object.") if received == :malformed
      return failure(@raw, "The arguments must be a JSON object of named values.") unless received.is_a?(Hash)

      values = {}
      @schema.each do |field, spec|
        value = received[field.to_s]
        if value.nil?
          return failure(received, "#{field} is required.") if spec[:required]
          next
        end

        coerced = coerce(value, spec)
        return failure(received, "#{field} #{describe(spec)} (got #{brief(value)}).") if coerced == :invalid

        values[field] = coerced
      end
      Result.new(values: values, received: received, error: nil)
    end

    private

    def decode
      case @raw
      when Hash then @raw.stringify_keys
      when nil then {}
      when String
        return {} if @raw.strip.empty?

        JSON.parse(@raw)
      else @raw
      end
    rescue JSON::ParserError
      :malformed
    end

    def coerce(value, spec)
      case spec[:type]
      when :integer then integer(value)
      when :string then string(value, spec[:enum])
      when :integer_list then value.is_a?(Array) ? integer_list(value) : :invalid
      end
    end

    def integer(value)
      case value
      when Integer then value
      when Float then value.finite? && value == value.to_i ? value.to_i : :invalid
      when String then value.match?(INTEGER_PATTERN) ? value.to_i : :invalid
      else :invalid
      end
    end

    def string(value, enum)
      return :invalid unless value.is_a?(String)
      return :invalid if enum && !enum.include?(value)

      value
    end

    def integer_list(values)
      coerced = values.map { |v| integer(v) }
      coerced.include?(:invalid) ? :invalid : coerced
    end

    def describe(spec)
      case spec[:type]
      when :integer then "must be a whole number"
      when :integer_list then "must be a list of whole-number ids"
      when :string then spec[:enum] ? "must be one of: #{spec[:enum].join(', ')}" : "must be text"
      end
    end

    def brief(value)
      text = value.is_a?(String) ? value : value.to_json
      text = "#{text[0, 40]}..." if text.length > 40
      text.inspect
    end

    def failure(received, message)
      Result.new(values: nil, received: received, error: message)
    end
  end
end

# Runs one tool call for a voice provider: parse arguments, dispatch to the business services, contain failures,
# time it and record it in tool_invocations. Returns the string the model is told. The runner knows tool names and
# argument shapes; the rules live in OrderTaking, CallLifecycle and MenuCatalog.
module Voice
  class ToolRunner
    NO_CALL_RESULT = "No active call found for this request.".freeze

    def self.call(call_log:, tool_call:, vapi_timestamp: nil)
      return NO_CALL_RESULT unless call_log

      new(call_log, tool_call, vapi_timestamp).call
    end

    def initialize(call_log, tool_call, vapi_timestamp)
      @call_log = call_log
      @tool_call = tool_call
      @vapi_timestamp = vapi_timestamp
    end

    def call
      started_at = Time.current
      clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      outcome = execute
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock) * 1000).round

      record(outcome, started_at: started_at, duration_ms: duration_ms)
      outcome[:result]
    end

    private

    # Returns { name:, arguments:, result:, status:, error_code:, error_class: }.
    def execute
      outcome = { name: nil, arguments: nil, status: "ok" }
      name = outcome[:name] = @tool_call.dig("function", "name") || @tool_call["name"]
      arguments = outcome[:arguments] = @tool_call.dig("function", "arguments") || @tool_call["arguments"] || {}

      arguments = outcome[:arguments] = JSON.parse(arguments) if arguments.is_a?(String)

      outcome[:result] = dispatch(name, arguments, outcome)
      outcome
    rescue => e
      Rails.logger.error("[Vapi] tool #{name} failed: #{e.class}: #{e.message}")
      outcome.merge(
        result: "Sorry, something went wrong handling that - #{e.message}",
        status: "error", error_class: e.class.name
      )
    end

    def dispatch(name, arguments, outcome)
      order_taking = OrderTaking.new(@call_log)

      case name
      when "get_menu" then MenuCatalog.new(@call_log.restaurant).full.to_json
      when "add_to_cart" then order_taking.add_item(arguments).payload.to_json
      when "update_cart_item_quantity" then order_taking.update_quantity(arguments).payload.to_json
      when "remove_cart_item" then order_taking.remove_item(arguments).payload.to_json
      when "get_cart" then order_taking.cart.payload.to_json
      when "submit_order"
        submitted = order_taking.submit(arguments)
        outcome.merge!(status: "rejected", error_code: submitted.rejection.to_s) if submitted.rejected?
        submitted.payload.to_json
      when "transfer_to_human"
        CallLifecycle.transfer(@call_log, arguments["reason"])
        "Transfer logged."
      else
        outcome.merge!(status: "rejected", error_code: "unknown_tool")
        "Unknown tool: #{name}"
      end
    end

    def record(outcome, started_at:, duration_ms:)
      tool_call_id = @tool_call["id"]
      return Rails.logger.warn("[Vapi] tool call without an id on call #{@call_log.external_call_id}; not recorded") if tool_call_id.blank?

      ToolInvocation.record!(
        call_log: @call_log, order: @call_log.reload.order, tool_call_id: tool_call_id, tool_name: outcome[:name].to_s,
        arguments: outcome[:arguments], result: outcome[:result], status: outcome[:status],
        error_code: outcome[:error_code], error_class: outcome[:error_class], started_at: started_at,
        duration_ms: duration_ms, vapi_requested_at: requested_at
      )
    rescue => e
      Rails.logger.error("[Vapi] could not record tool invocation #{tool_call_id}: #{e.class}: #{e.message}")
    end

    def requested_at
      return unless @vapi_timestamp.is_a?(Numeric)

      Time.zone.at(@vapi_timestamp.to_i / 1000, @vapi_timestamp.to_i % 1000, :millisecond)
    end
  end
end

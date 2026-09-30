# Runs one tool call for a voice provider: validate arguments, dispatch to the business services, contain
# failures, time it and record it in tool_invocations. Returns the string the model is told.
#
# Result contract (a string of JSON): successes are the tool's payload; every failure is
#   {"ok":false,"error":{"code":"...","message":"<speakable guidance>"}}
# and never contains exception text. The runner knows tool names and argument shapes; the rules live in
# OrderTaking, CallLifecycle and MenuCatalog.
module Voice
  class ToolRunner
    Result = OrderTaking::Result

    MESSAGES = {
      no_active_call: "There is no active call for this request. Apologize and offer to transfer the caller to a person.",
      unknown_tool: "That tool doesn't exist. Use only the tools you were given.",
      internal_error: "Something went wrong on our side. Apologize briefly and offer to transfer the caller to a person."
    }.freeze

    def self.error_json(code, message) = { ok: false, error: { code: code.to_s, message: message } }.to_json

    def self.call(call_log:, tool_call:, vapi_timestamp: nil)
      return error_json(:no_active_call, MESSAGES.fetch(:no_active_call)) unless call_log

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
      raw_arguments = @tool_call.dig("function", "arguments") || @tool_call["arguments"]
      outcome[:arguments] = raw_arguments

      return reject(outcome, :unknown_tool, MESSAGES.fetch(:unknown_tool)) unless ToolArguments.known?(name)

      parsed = ToolArguments.parse(name, raw_arguments)
      outcome[:arguments] = parsed.received
      return reject(outcome, :invalid_arguments, parsed.error) unless parsed.ok?

      result = dispatch(name, parsed.values)
      return reject(outcome, result.rejection, result.message) if result.rejected?

      outcome.merge(result: serialize(result.payload))
    rescue ActiveRecord::RecordInvalid => e
      fields = e.record.errors.attribute_names.map { |a| a.to_s.tr("_", " ") }.to_sentence
      reject(outcome, :invalid_arguments, "The request wasn't valid#{": check #{fields}" if fields.present?}.")
    rescue => e
      Rails.logger.error("[Vapi] tool #{name} failed on call #{@call_log.external_call_id}: #{e.class}: #{e.message}")
      outcome.merge(
        result: self.class.error_json(:internal_error, MESSAGES.fetch(:internal_error)),
        status: "error", error_code: "internal_error", error_class: e.class.name
      )
    end

    def dispatch(name, values)
      order_taking = OrderTaking.new(@call_log)

      case name
      when "get_menu" then Result.ok(MenuCatalog.new(@call_log.restaurant).full)
      when "add_to_cart" then order_taking.add_item(**values)
      when "update_cart_item_quantity" then order_taking.update_quantity(**values)
      when "remove_cart_item" then order_taking.remove_item(**values)
      when "get_cart" then order_taking.cart
      when "submit_order" then order_taking.submit(**values)
      when "transfer_to_human"
        CallLifecycle.transfer(@call_log, values[:reason])
        Result.ok("Transfer logged.")
      end
    end

    def serialize(payload) = payload.is_a?(String) ? payload : payload.to_json

    def reject(outcome, code, message)
      outcome.merge(result: self.class.error_json(code, message), status: "rejected", error_code: code.to_s)
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

    # Vapi's message timestamp is epoch milliseconds (an Integer in the live payloads; tolerate numeric strings).
    def requested_at
      millis = case @vapi_timestamp
      when Numeric then @vapi_timestamp.to_i
      when /\A\d+\z/ then @vapi_timestamp.to_i
      end
      Time.zone.at(millis / 1000, millis % 1000, :millisecond) if millis
    end
  end
end

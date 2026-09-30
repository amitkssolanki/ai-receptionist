# Runs one tool call for a voice provider: validate arguments, dispatch to the business services, contain
# failures, time it and record it in tool_invocations - all in one transaction (see #call). Returns the string the
# model is told.
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

    def self.error_json(code, message, details = {})
      { ok: false, error: { code: code.to_s, message: message }.merge(details) }.to_json
    end

    def self.call(call_log:, tool_call:, vapi_timestamp: nil)
      return error_json(:no_active_call, MESSAGES.fetch(:no_active_call)) unless call_log

      new(call_log, tool_call, vapi_timestamp).call
    end

    # The recording could not be written (not a business failure). Raised inside the transaction so the business
    # change rolls back with it; #call then serves the request once, unrecorded.
    AuditFailure = Class.new(StandardError)

    def initialize(call_log, tool_call, vapi_timestamp)
      @call_log = call_log
      @tool_call = tool_call
      @vapi_timestamp = vapi_timestamp
    end

    # One transaction per tool call:
    #
    #   BEGIN
    #     lock the call row                      (call_logs -> orders, the order every mutation already uses)
    #     a ToolInvocation for this (call, toolCallId) exists?  -> replay_count += 1, return its stored result
    #     otherwise: run the tool (inside a savepoint, so a failure undoes only its own writes),
    #                insert the ToolInvocation (result, status, cart versions, timing)
    #   COMMIT
    #
    # The business change and its audit record therefore commit or roll back together, and a redelivered tool call
    # can never execute twice: concurrent deliveries queue on the call row lock, and the loser finds the winner's
    # committed row. The unique index stays as the backstop.
    def call
      return run_unrecorded if tool_call_id.blank?

      attempts = 0
      begin
        attempts += 1
        run_recorded
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 2 # something beat us to the row without taking the lock; the retry replays it
        raise
      end
    rescue AuditFailure => e
      Rails.logger.error("[Vapi] could not record tool invocation #{tool_call_id}: #{e.cause.class}: #{e.cause&.message}; served unrecorded")
      run_unrecorded
    end

    private

    def tool_call_id = @tool_call["id"]

    def run_recorded
      ApplicationRecord.transaction do
        @call_log.lock!
        existing = ToolInvocation.find_by(call_log_id: @call_log.id, tool_call_id: tool_call_id)
        existing ? replay(existing) : execute_and_record
      end
    end

    def replay(existing)
      existing.register_replay!
      Rails.logger.info("[Vapi] replayed tool call #{tool_call_id} on call #{@call_log.external_call_id} (x#{existing.replay_count}); stored result returned")
      existing.result
    end

    def execute_and_record
      started_at = Time.current
      clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      before = cart_version
      outcome = execute
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock) * 1000).round

      begin
        ApplicationRecord.transaction(requires_new: true) do
          ToolInvocation.record!(
            call_log: @call_log, order: @call_log.reload.order, tool_call_id: tool_call_id,
            tool_name: outcome[:name].to_s.strip.presence&.first(100) || "(none)",
            arguments: outcome[:arguments], result: outcome[:result], status: outcome[:status],
            error_code: outcome[:error_code], error_class: outcome[:error_class], started_at: started_at,
            duration_ms: duration_ms, vapi_requested_at: requested_at,
            cart_version_before: before, cart_version_after: cart_version
          )
        end
      rescue ActiveRecord::RecordNotUnique
        raise
      rescue => e
        raise AuditFailure, e.message
      end
      outcome[:result]
    end

    # Degraded path (no toolCallId to key on, or the audit row could not be written): still atomic per call, but
    # neither idempotent nor recorded.
    def run_unrecorded
      Rails.logger.warn("[Vapi] tool call without an id on call #{@call_log.external_call_id}; not recorded") if tool_call_id.blank?
      ApplicationRecord.transaction do
        @call_log.lock!
        execute[:result]
      end
    end

    # The model-visible cart version: 0 while there is no order.
    def cart_version = @call_log.reload.order&.cart_version || 0

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

      result = ApplicationRecord.transaction(requires_new: true) { dispatch(name, parsed.values) }
      return reject(outcome, result.rejection, result.message, result.details) if result.rejected?

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
      when "get_menu" then Result.ok({ categories: MenuCatalog.new(@call_log.restaurant).overview })
      when "get_menu_item" then menu_item(values[:menu_item_id])
      when "add_to_cart" then order_taking.add_item(**values)
      when "update_cart_item_quantity" then order_taking.update_quantity(**values)
      when "remove_cart_item" then order_taking.remove_item(**values)
      when "get_cart" then order_taking.read_back
      when "submit_order" then order_taking.submit(**values)
      when "transfer_to_human"
        CallLifecycle.transfer(@call_log, values[:reason])
        Result.ok({ message: "Transfer logged." })
      end
    end

    def menu_item(id)
      item = MenuCatalog.new(@call_log.restaurant).item(id)
      item ? Result.ok(item) : Result.rejected(:menu_item_unavailable, OrderTaking::MESSAGES.fetch(:menu_item_unavailable))
    end

    # Successful payloads are objects and carry "ok": true.
    def serialize(payload) = { ok: true }.merge(payload).to_json

    def reject(outcome, code, message, details = {})
      outcome.merge(result: self.class.error_json(code, message, details), status: "rejected", error_code: code.to_s)
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

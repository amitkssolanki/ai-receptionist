module ConsoleView
  # Server events for one call in time order: tool executions (ToolInvocation) and call lifecycle transitions.
  class Timeline
    LifecycleEntry = Data.define(:kind, :at, :offset, :text) do
      def dom_id(call_log) = "lifecycle_#{call_log.id}_#{kind}"
    end

    attr_reader :call_log

    def initialize(call_log)
      @call_log = call_log
    end

    def entries
      (tool_events + lifecycle_entries).sort_by { |entry| [ entry.at || Time.zone.at(0), entry.is_a?(LifecycleEntry) ? 0 : 1 ] }
    end

    def tool_events
      call_log.tool_invocations.order(:started_at, :id).map { |invocation| Event.new(invocation, call_log) }
    end

    def lifecycle_entries
      [ started_entry, transferred_entry, ended_entry ].compact
    end

    def self.lifecycle_entry(call_log, kind) = new(call_log).lifecycle_entries.find { |entry| entry.kind == kind }

    private

    def entry(kind, at, text) = LifecycleEntry.new(kind, at, ConsoleView.offset(at, call_log.started_at), text)

    def started_entry = call_log.started_at && entry(:started, call_log.started_at, "call started")

    def transferred_entry
      return unless call_log.transferred_at

      entry(:transferred, call_log.transferred_at, "transferred to a person#{": #{call_log.transfer_reason.to_s.truncate(80)}" if call_log.transfer_reason.present?}")
    end

    # Placed where the call really ended (start + duration): Vapi's report can arrive a minute later.
    def ended_entry
      return unless call_log.ended_at

      at = call_log.duration_seconds && call_log.started_at ? call_log.started_at + call_log.duration_seconds : call_log.ended_at
      parts = [ "call ended", call_log.ended_reason, ("#{call_log.duration_seconds}s" if call_log.duration_seconds), ("$#{'%.4f' % call_log.cost_usd}" if call_log.cost_usd) ]
      entry(:ended, at, parts.compact.join(" · "))
    end
  end
end

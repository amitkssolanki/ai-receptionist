module ConsoleView
  # The server's account of the call itself (status, timing, outcome, tool tallies).
  class Status
    attr_reader :call_log

    def initialize(call_log)
      @call_log = call_log
    end

    def label = call_log.status.to_s.tr("_", " ").upcase
    def ended? = call_log.ended_at.present?
    def started = ConsoleView.clock(call_log.started_at, call_log.restaurant)
    def duration = call_log.duration_seconds ? "#{call_log.duration_seconds}s" : nil
    def cost = call_log.cost_usd ? format("$%.4f", call_log.cost_usd) : nil

    def tools
      counts = call_log.tool_invocations.group(:status).count
      { ok: counts.fetch("ok", 0), rejected: counts.fetch("rejected", 0), error: counts.fetch("error", 0) }
    end

    def duplicates_absorbed = call_log.tool_invocations.sum(:replay_count)
  end
end

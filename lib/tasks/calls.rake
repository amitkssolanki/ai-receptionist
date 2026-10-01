namespace :calls do
  desc "Payload-free summary of the most recent call (or CALL=<id>): status, tool calls, versions, order. Safe to paste."
  task last: :environment do
    call_log = ENV["CALL"].present? ? CallLog.find(ENV["CALL"]) : CallLog.order(:id).last
    abort "No calls yet." unless call_log

    status = ConsoleView::Status.new(call_log)
    board = ConsoleView::Board.new(call_log)
    puts "call ##{call_log.id}  #{call_log.status}  console session: #{call_log.console_session_key.present? ? 'yes (token arrived)' : 'no'}  started #{status.started}#{'  FAULT INJECTION (test assistant)' if status.fault_injection?}"
    puts "ended: #{call_log.ended_reason.presence || (status.ended? ? 'yes' : 'not yet')}  #{status.duration}  #{status.cost}  assistant #{call_log.assistant_version || '-'}"
    puts "tools: ok #{status.tools[:ok]}  rejected #{status.tools[:rejected]}  error #{status.tools[:error]}  duplicates absorbed #{status.duplicates_absorbed}"
    ConsoleView::Timeline.new(call_log).entries.each do |entry|
      if entry.is_a?(ConsoleView::Timeline::LifecycleEntry)
        puts "  #{entry.offset}  ● #{entry.text}"
      else
        puts format("  %s  %-26s %-8s %-10s %-9s %4dms  %s", entry.offset, entry.tool, entry.status, entry.code.to_s, entry.cart_label.tr(" ", ""), entry.server_ms, entry.result_summary.tr("\n", " ")[0, 90])
        # Submit rows: elapsed time plus the shadow-mode turn evidence (counts and flags only, never refused).
        entry.observations.each { |observation| puts "           #{observation.icon} #{observation.text}" } if entry.tool == "submit_order"
      end
    end
    puts "order: #{board.present? ? "##{board.order_id} #{board.status_label} v#{board.cart_version} $#{'%.2f' % board.total}  read-back: #{board.read_back}  sms: #{board.sms}" : 'none'}"
    board.lines.each { |line| puts "  #{line.quantity} x #{line.name}#{" (#{line.modifiers.map { |m| m[:name] }.join(', ')})" if line.modifiers.any?}" }
  end
end

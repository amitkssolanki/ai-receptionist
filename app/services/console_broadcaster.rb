# Pushes the server's committed state to the voice console over Action Cable (Turbo Streams). It is the only place that
# broadcasts, and everything it sends is rendered from the database after the change committed:
#
#   tool call   -> 1. the event row  2. the order board (if an order exists)  3. the call status   (fixed order)
#   lifecycle   -> the lifecycle row, the order board, the call status
#   attached    -> on the console-session stream: subscribe to the call's stream and load its state
#
# Board and status are full snapshots (replace), event rows have stable DOM ids (tool_call_<id>), so a missed or
# repeated message cannot leave the page wrong; a reconnect reloads the persisted state anyway. A failure here is
# logged (class only) and never reaches the tool response or the business transaction.
module ConsoleBroadcaster
  STATE_TARGETS = { events: "events", board: "order-board", status: "call-status" }.freeze

  module_function

  def stream_for(call_log) = [ call_log, :console ]

  # Run the block once the surrounding transaction has really committed (immediately when there is none).
  def after_commit(&block)
    ActiveRecord.after_all_transactions_commit { safely(&block) }
  end

  def tool_call(invocation)
    call_log = invocation.call_log
    row = ConsoleView::Event.new(invocation, call_log)
    if invocation.replay_count.positive?
      replace(call_log, row.dom_id, "admin/console/event", event: row)
    else
      append(call_log, STATE_TARGETS[:events], "admin/console/event", event: row)
    end
    snapshot(call_log, status: true, board: invocation.order_id.present?)
  end

  def lifecycle(call_log, kind)
    entry = ConsoleView::Timeline.lifecycle_entry(call_log, kind)
    append(call_log, STATE_TARGETS[:events], "admin/console/lifecycle_event", entry: entry, call_log: call_log) if entry
    snapshot(call_log, status: true, board: call_log.order_id.present?)
  end

  # Tells the console page that started this call (identified by its session key) that the call now exists.
  def call_attached(call_log)
    return if call_log.console_session_key.blank?

    Turbo::StreamsChannel.broadcast_update_to(
      [ :console_session, call_log.console_session_key ], target: "console-call",
      partial: "admin/console/call_attached", locals: { call_log: call_log }
    )
  end

  def snapshot(call_log, status: true, board: true)
    replace(call_log, STATE_TARGETS[:board], "admin/console/order_board", call_log: call_log) if board
    replace(call_log, STATE_TARGETS[:status], "admin/console/call_status", call_log: call_log) if status
  end

  def append(call_log, target, partial, locals)
    Turbo::StreamsChannel.broadcast_append_to(stream_for(call_log), target: target, partial: partial, locals: locals)
  end

  def replace(call_log, target, partial, locals)
    Turbo::StreamsChannel.broadcast_replace_to(stream_for(call_log), target: target, partial: partial, locals: locals)
  end

  def safely
    yield
  rescue => e
    Rails.logger.error("[Console] broadcast failed: #{e.class}")
  end
end

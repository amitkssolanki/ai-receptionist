# Phase 1: a browser console call carries the session key the console page generated (how the console finds "its"
# call), and the end-of-call report's outcome facts are kept on the call (PLAN section 4).
class AddConsoleAndOutcomeFieldsToCallLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :call_logs, :console_session_key, :string
    add_index :call_logs, :console_session_key
    add_column :call_logs, :ended_reason, :string
    add_column :call_logs, :duration_seconds, :integer
    add_column :call_logs, :cost_usd, :decimal, precision: 10, scale: 4
    add_column :call_logs, :assistant_version, :string
  end
end

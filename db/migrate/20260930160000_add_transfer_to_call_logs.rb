# Phase 1 / Step 8: a transfer is recorded as facts on the call (when, why) instead of a line in the transcript, so
# the end-of-call report can never overwrite it.
class AddTransferToCallLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :call_logs, :transferred_at, :datetime, precision: 3
    add_column :call_logs, :transfer_reason, :string
  end
end

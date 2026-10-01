# Phase 1 / Step 1: audit trail of server-side tool executions (see docs/phase1/PLAN.md section 4).
class CreateToolInvocations < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_invocations do |t|
      t.references :call_log, null: false, foreign_key: true, index: false
      t.references :order, foreign_key: true
      t.string :tool_call_id, null: false
      t.string :source, null: false, default: "vapi"
      t.string :tool_name, null: false
      t.jsonb :arguments
      t.jsonb :result
      t.string :status, null: false
      t.string :error_code
      t.string :error_class
      t.integer :cart_version_before
      t.integer :cart_version_after
      t.datetime :vapi_requested_at, precision: 3
      t.datetime :started_at, precision: 3, null: false
      t.datetime :finished_at, precision: 3, null: false
      t.integer :duration_ms, null: false
      t.integer :replay_count, null: false, default: 0
      t.timestamps
    end

    add_index :tool_invocations, [ :call_log_id, :tool_call_id ], unique: true
    add_index :tool_invocations, [ :call_log_id, :started_at ]
  end
end

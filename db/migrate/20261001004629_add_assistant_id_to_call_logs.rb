class AddAssistantIdToCallLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :call_logs, :assistant_id, :string,
               comment: "The Vapi assistant that handled the call (from the authenticated webhook). Evidence only: never used for authorization or business rules."
  end
end

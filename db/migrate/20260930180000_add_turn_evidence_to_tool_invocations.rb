class AddTurnEvidenceToToolInvocations < ActiveRecord::Migration[8.1]
  def change
    add_column :tool_invocations, :turn_evidence, :jsonb,
               comment: "submit_order only, shadow mode: caller turn-taking observed in Vapi's conversation history (counts/flags/ids; never text). Not enforced."
  end
end

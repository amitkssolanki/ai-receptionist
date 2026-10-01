# One row per tool execution the server performed for a call: what Vapi asked for, what we ran, and exactly what
# the model was told. An audit trail, not an event store - orders stay the source of truth.
class ToolInvocation < ApplicationRecord
  ARGUMENTS_BYTE_LIMIT = 4096

  belongs_to :call_log
  belongs_to :order, optional: true

  enum :status, { ok: "ok", rejected: "rejected", error: "error" }, validate: true
  enum :source, { vapi: "vapi", replay: "replay" }, validate: true

  validates :tool_call_id, :tool_name, :started_at, :finished_at, :duration_ms, presence: true

  # Inserts the record of one execution. Voice::ToolRunner calls this inside the same transaction as the business
  # change; the unique (call_log_id, tool_call_id) index is the backstop that makes a second record impossible.
  # turn_evidence (submit_order only) is a shadow-mode observation from Voice::TurnEvidence; it is never enforced.
  def self.record!(call_log:, tool_call_id:, tool_name:, arguments:, result:, status:, started_at:, duration_ms:,
                   order: nil, error_code: nil, error_class: nil, vapi_requested_at: nil, source: "vapi",
                   cart_version_before: nil, cart_version_after: nil, turn_evidence: nil)
    create!(
      call_log: call_log, order: order, tool_call_id: tool_call_id, source: source, tool_name: tool_name,
      arguments: cap_arguments(arguments), result: result, status: status, error_code: error_code,
      error_class: error_class, vapi_requested_at: vapi_requested_at, started_at: started_at,
      finished_at: started_at + duration_ms / 1000.0, duration_ms: duration_ms,
      cart_version_before: cart_version_before, cart_version_after: cart_version_after, turn_evidence: turn_evidence
    )
  end

  # A redelivery of this tool call was detected and answered from the stored result (nothing re-executed).
  def register_replay!
    increment!(:replay_count)
  end

  def self.cap_arguments(arguments)
    json = arguments.to_json
    return arguments if json.bytesize <= ARGUMENTS_BYTE_LIMIT

    { "_truncated" => true, "_bytes" => json.bytesize, "_preview" => json.byteslice(0, 1000).scrub }
  end
end

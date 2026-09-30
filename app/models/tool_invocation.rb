# One row per tool execution the server performed for a call: what Vapi asked for, what we ran, and exactly what
# the model was told. An audit trail, not an event store - orders stay the source of truth.
class ToolInvocation < ApplicationRecord
  ARGUMENTS_BYTE_LIMIT = 4096

  belongs_to :call_log
  belongs_to :order, optional: true

  enum :status, { ok: "ok", rejected: "rejected", error: "error" }, validate: true
  enum :source, { vapi: "vapi", replay: "replay" }, validate: true

  validates :tool_call_id, :tool_name, :started_at, :finished_at, :duration_ms, presence: true

  # Records one execution. A repeat delivery of the same (call, toolCallId) does not add a row; it bumps
  # replay_count on the original.
  def self.record!(call_log:, tool_call_id:, tool_name:, arguments:, result:, status:, started_at:, duration_ms:,
                   order: nil, error_code: nil, error_class: nil, vapi_requested_at: nil, source: "vapi")
    existing = find_by(call_log: call_log, tool_call_id: tool_call_id)
    return existing.tap { |row| row.increment!(:replay_count) } if existing

    create!(
      call_log: call_log, order: order, tool_call_id: tool_call_id, source: source, tool_name: tool_name,
      arguments: cap_arguments(arguments), result: result, status: status, error_code: error_code,
      error_class: error_class, vapi_requested_at: vapi_requested_at, started_at: started_at,
      finished_at: started_at + duration_ms / 1000.0, duration_ms: duration_ms
    )
  end

  def self.cap_arguments(arguments)
    json = arguments.to_json
    return arguments if json.bytesize <= ARGUMENTS_BYTE_LIMIT

    { "_truncated" => true, "_bytes" => json.bytesize, "_preview" => json.byteslice(0, 1000).scrub }
  end
end

# Reliability evaluation around one claim: "The model proposes. The server decides."
#
# A scenario is a scripted conversation plus tool calls - recorded from a real call, or a variation of it - that is run
# through the REAL server path (Voice::ToolRunner -> OrderTaking -> ToolInvocation) inside a rolled-back transaction. For
# each one the harness separates four things that a demo can blur:
#   1. what the assistant CLAIMED (transcript lines that say it changed the order)
#   2. what tool calls the server actually RECEIVED and recorded (ToolInvocation)
#   3. which of those actually MUTATED the cart (cart_version moved)
#   4. the resulting AUTHORITATIVE order
# and then reports every claim the server's order does not reflect, without ever "fixing" it.
#
# Nothing here calls a model or Vapi. The scripted assistant behaviour comes from recordings (call #7) and deliberate
# variations; a live-model sample (plan Layer 3a) is a separate, pending step that needs Vapi/OpenAI access.
module Evaluation
  Event = Data.define(:t, :kind, :role, :text, :tool_call_id, :tool, :args)
  Scenario = Data.define(:id, :title, :purpose, :events)

  def self.say(t, role, text) = Event.new(t: t, kind: :say, role: role, text: text, tool_call_id: nil, tool: nil, args: nil)

  # args: a Hash, or a lambda taking the World (for ids that only exist at run time).
  def self.tool(t, id, name, args = {}) = Event.new(t: t, kind: :tool, role: nil, text: nil, tool_call_id: id, tool: name, args: args)
end

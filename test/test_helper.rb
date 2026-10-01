ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Tests never see the developer's real Vapi credentials (private key, public key, dev assistant id, webhook secret). The
# encrypted credentials now hold them for local use, and a test that expects "no secret configured" must not depend on
# whoever runs it. Tests that need a value set the ENV var or stub credentials explicitly. In-memory only: the file is untouched.
Rails.application.credentials.then do |credentials|
  credentials.config.delete(:vapi)
  credentials.instance_variable_set(:@options, nil) # rebuilt lazily from config
end

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
  end
end

# Business hours that never close (the order rules refuse orders when the restaurant is closed).
ALWAYS_OPEN_HOURS = %w[sun mon tue wed thu fri sat].index_with { "24h" }.freeze

# A Vapi-shaped conversation history (webhook `artifact`) for a submit_order tool call, in the structure of the live
# payloads (test/fixtures/files/vapi/live_submit_webhook_*.json): the last get_cart result, `caller_turns` caller
# utterances, then the submit's own tool_calls entry. The server's confirmation gate needs at least one caller turn
# there (Voice::TurnEvidence / OrderTaking#submit). Tests that mean "the caller answered the read-back" send
# VapiHistory.answered(submit_id); tests of the gate itself build the other shapes.
module VapiHistory
  module_function

  def answered(submit_id) = for_submit(submit_id, caller_turns: 1)

  def for_submit(submit_id, caller_turns:, get_cart_id: "history_get_cart", same_completion: false)
    messages = [ { "role" => "tool_call_result", "name" => "get_cart", "toolCallId" => get_cart_id, "time" => 1_000 } ]
    caller_turns.times { |i| messages << { "role" => "user", "message" => "Yes, that's right.", "time" => 2_000 + i } }
    messages << { "role" => "tool_calls", "time" => 3_000, "toolCalls" => [ { "id" => submit_id.to_s, "function" => { "name" => "submit_order" } } ] }

    get_cart_call = { "role" => "assistant", "content" => nil, "tool_calls" => [ { "id" => get_cart_id, "function" => { "name" => "get_cart" } } ] }
    submit_call = { "id" => submit_id.to_s, "function" => { "name" => "submit_order" } }
    openai = [ get_cart_call, { "role" => "tool", "tool_call_id" => get_cart_id, "content" => "{}" } ]
    openai += Array.new(caller_turns) { { "role" => "user", "content" => "Yes, that's right." } }
    openai << (same_completion && caller_turns.zero? ? { "role" => "assistant", "content" => "One pizza, sixteen dollars. Did I get that right?", "tool_calls" => [ submit_call ] }
                                                     : { "role" => "assistant", "content" => nil, "tool_calls" => [ submit_call ] })
    { "messages" => messages, "messagesOpenAIFormatted" => openai }
  end

  # For helpers that route every tool through Voice::ToolRunner: a history only for submit_order, where the caller answered.
  def for_tool(name, id) = (answered(id) if name == "submit_order")
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
end

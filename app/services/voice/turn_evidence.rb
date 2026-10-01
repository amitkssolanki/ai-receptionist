# What the conversation history in Vapi's tool-calls webhook shows about turn-taking at the moment submit_order was
# requested: did the caller say anything after the agent last received a get_cart result? It feeds the server's
# confirmation gate (OrderTaking#submit refuses without a caller turn after the read-back) and is recorded on every
# submit_order. It is evidence of turn separation, not of confirmation: a caller turn proves the caller spoke, never
# that they said yes. The gate uses only the caller-turn count; `completion` (and its speech_chars, which lags behind
# the spoken audio in the live history) is recorded for explanation only and never decides anything.
#
# Source: message["artifact"], which Vapi sends with every tool-calls webhook as "a live version of call.artifact".
# Shape verified against the live submit_order webhooks of calls #8, #9 and #13 (structure-only copies in
# test/fixtures/files/vapi/live_submit_webhook_*.json):
#
#   artifact.messages - one entry per event, in order:
#     { role: "system" | "bot" | "user", message:, time: <epoch ms>, endTime:, secondsFromStart:, duration: }
#     { role: "tool_calls", time:, toolCalls: [{ id:, function: { name: } }] }        (the in-flight submit is included)
#     { role: "tool_call_result", time:, name:, toolCallId:, result: }
#   artifact.messagesOpenAIFormatted - the model's view; one "assistant" entry per model completion:
#     { role: "assistant", content: <spoken text or null>, tool_calls: [{ id:, function: { name: } }] }
#     { role: "tool", tool_call_id:, content: }   { role: "user", content: }
#
# Two findings from those payloads drive the rules below:
# - The payload is built slightly after the tool call, so caller speech that began AFTER the submit was requested can
#   already be in it (call #9: the caller's "yes" starts 104 ms after the submit request). Counting stops at the
#   submit's own tool_calls entry; later caller turns are reported separately and never counted.
# - Completion boundaries exist only in messagesOpenAIFormatted (in `messages` a completion's speech and its tool call
#   are separate entries), so "same completion" is read from there.
#
# Privacy: only counts, booleans, millisecond gaps, tool names and Vapi's opaque tool-call ids are returned. No
# transcript or spoken text leaves this method (speech is measured by length only).
module Voice
  module TurnEvidence
    # 2: the evidence gates submit_order ("mode" => "enforced"). Rows with schema 1 were recorded in shadow mode.
    SCHEMA = 2

    module_function

    # Always returns a small JSON-safe Hash; never raises.
    def for_submit(artifact, tool_call_id:)
      base = { "schema" => SCHEMA, "mode" => "enforced" }
      return base.merge("artifact_messages" => "missing") if artifact.nil?
      return base.merge("artifact_messages" => "malformed") unless artifact.is_a?(Hash)

      messages = artifact["messages"]
      return base.merge("artifact_messages" => "missing") if messages.nil?
      return base.merge("artifact_messages" => "malformed") unless messages.is_a?(Array)

      base.merge("artifact_messages" => "present", "messages_count" => messages.size)
          .merge(turns(messages, tool_call_id))
          .merge("completion" => completion(artifact["messagesOpenAIFormatted"], tool_call_id))
    rescue StandardError => e
      { "schema" => SCHEMA, "mode" => "enforced", "artifact_messages" => "malformed", "error" => e.class.name.first(80) }
    end

    # The confirmation gate's input: at least one caller turn between the last get_cart result and this submit's own
    # entry in a history that is present and readable. Anything else - missing or malformed history, no get_cart result
    # in it, the submit not found in it - is false: the gate fails closed. Deliberately ignores `completion` and
    # speech_chars.
    def caller_turn_after_read_back?(evidence)
      evidence.is_a?(Hash) && evidence["artifact_messages"] == "present" && evidence["submit_request_found"] == true &&
        evidence["caller_turns_since_last_get_cart"].is_a?(Integer) && evidence["caller_turns_since_last_get_cart"] >= 1
    end

    # Caller turns between the last get_cart result and this submit's own tool_calls entry, by position in the list.
    def turns(messages, tool_call_id)
      anomalies = []
      entries = messages.select { |m| m.is_a?(Hash) }
      anomalies << "non_object_entries" if entries.size != messages.size

      submit_index = entries.rindex { |m| m["role"] == "tool_calls" && tool_call_ids(m["toolCalls"]).include?(tool_call_id.to_s) }
      anomalies << "submit_request_not_in_history" unless submit_index
      window_end = submit_index || entries.size

      cart_index = entries[0...window_end].rindex { |m| m["role"] == "tool_call_result" && m["name"] == "get_cart" }
      between = cart_index ? entries[(cart_index + 1)...window_end].select { |m| m["role"] == "user" } : []
      after = submit_index ? entries[(submit_index + 1)..].select { |m| m["role"] == "user" } : []

      submit_at = submit_index && millis(entries[submit_index]["time"])
      cart_at = cart_index && millis(entries[cart_index]["time"])
      anomalies << "caller_turn_timed_after_submit" if submit_at && between.any? { |m| (t = millis(m["time"])) && t > submit_at }
      next_caller_at = after.filter_map { |m| millis(m["time"]) }.min

      {
        "submit_request_found" => !submit_index.nil?,
        "last_get_cart_tool_call_id" => cart_index ? entries[cart_index]["toolCallId"]&.to_s&.first(100) : nil,
        "caller_turns_since_last_get_cart" => cart_index ? between.size : nil,
        "caller_turns_after_submit_request" => submit_index ? after.size : nil,
        "ms_last_get_cart_result_to_submit_request" => (submit_at - cart_at if submit_at && cart_at),
        "ms_submit_request_to_next_caller_turn" => (next_caller_at - submit_at if next_caller_at && submit_at),
        "anomalies" => anomalies
      }
    end

    # The model completion that issued this submit, from the OpenAI-formatted history.
    def completion(openai_messages, tool_call_id)
      return { "available" => false } unless openai_messages.is_a?(Array)

      entries = openai_messages.select { |m| m.is_a?(Hash) }
      index = entries.index { |m| m["role"] == "assistant" && tool_call_ids(m["tool_calls"]).include?(tool_call_id.to_s) }
      return { "available" => true, "found" => false } unless index

      completion = entries[index]
      names = tool_names_by_id(entries)
      previous = index.positive? ? entries[index - 1] : nil
      responds_to_get_cart = previous.is_a?(Hash) && previous["role"] == "tool" && names[previous["tool_call_id"].to_s] == "get_cart"

      {
        "available" => true,
        "found" => true,
        # The completion was generated in direct response to a get_cart result: no caller turn and no other tool
        # result in between. When that completion also spoke, the read-back and the submit came out together.
        "responds_to_get_cart_result" => responds_to_get_cart,
        "speech_chars" => completion["content"].is_a?(String) ? completion["content"].strip.length : 0,
        "tool_calls" => Array(completion["tool_calls"]).filter_map { |t| t.dig("function", "name").to_s.first(64) if t.is_a?(Hash) }
      }
    end

    def tool_call_ids(tool_calls)
      Array(tool_calls).filter_map { |t| t["id"].to_s if t.is_a?(Hash) && t["id"] }
    end

    def tool_names_by_id(entries)
      entries.flat_map { |m| m["role"] == "assistant" ? Array(m["tool_calls"]) : [] }
             .each_with_object({}) { |t, h| h[t["id"].to_s] = t.dig("function", "name") if t.is_a?(Hash) && t["id"] }
    end

    def millis(value)
      case value
      when Integer then value
      when Float then value.round
      when /\A\d+\z/ then value.to_i
      end
    end
  end
end

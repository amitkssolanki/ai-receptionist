module ConsoleView
  # One row of the server event stream: a ToolInvocation as the server recorded it (not as Vapi announced it).
  class Event
    attr_reader :invocation, :call_log

    def initialize(invocation, call_log)
      @invocation = invocation
      @call_log = call_log
    end

    def dom_id = "tool_call_#{ConsoleView.dom_token(invocation.tool_call_id)}"
    def at = invocation.started_at
    def offset = ConsoleView.offset(invocation.started_at, call_log.started_at)
    def tool = invocation.tool_name
    def server_ms = invocation.duration_ms
    def replays = invocation.replay_count
    def status = invocation.status
    def code = invocation.error_code

    def cart_changed? = invocation.cart_version_after && invocation.cart_version_before && invocation.cart_version_after != invocation.cart_version_before

    def cart_label
      before = invocation.cart_version_before
      after = invocation.cart_version_after
      return "–" if before.nil? || after.nil?

      before == after ? "v#{after}" : "v#{before} → v#{after}"
    end

    def badge
      case status
      when "ok" then "✓ ok"
      when "rejected" then "⛔ rejected · #{code}"
      else "✖ #{code || 'error'}"
      end
    end

    # Display-only observations computed from server facts, never refusals. icon: "⏱" timing / cart facts,
    # "◌" shadow-mode turn evidence from Vapi's conversation history (observed, not enforced).
    Observation = Data.define(:text, :warn, :icon) do
      def initialize(text:, warn:, icon: "⏱") = super
    end

    def observations = [ submit_elapsed, *submit_turn_evidence, second_line ].compact

    # Arguments with ids resolved to names; free text and addresses summarised, never echoed.
    def arguments_summary
      args = invocation.arguments
      return "(unparseable arguments)" unless args.is_a?(Hash)

      case tool
      when "add_to_cart" then add_summary(args)
      when "update_cart_item_quantity" then "#{line_name(args['order_item_id'])} → qty #{args['quantity']}"
      when "remove_cart_item" then line_name(args["order_item_id"])
      when "get_menu_item" then item_name(args["menu_item_id"])
      when "submit_order" then submit_summary(args)
      when "transfer_to_human" then args["reason"].present? ? "reason: #{args['reason'].to_s.truncate(80)}" : "–"
      else "–"
      end
    end

    # A short account of what the server answered. Errors carry the code and the speakable guidance the model was given.
    def result_summary
      body = parsed_result
      return "(no result)" unless body.is_a?(Hash)
      return confirmation_refused_summary(body) if body.dig("error", "code") == "customer_confirmation_required"
      return "#{body.dig('error', 'code')}: #{body.dig('error', 'message').to_s.truncate(140)}" if body["ok"] == false

      case tool
      when "get_menu" then "#{Array(body['categories']).size} categories · #{Array(body['categories']).sum { |c| Array(c['items']).size }} items"
      when "get_menu_item" then body["name"].to_s
      when "get_cart" then "read-back v#{body['cart_version']} · total #{money(body['total'])}"
      when "submit_order" then submit_result(body)
      when "transfer_to_human" then body["message"].to_s
      else body["confirmation_text"].to_s.presence || "total #{money(body['total'])}"
      end
    end

    # The exact answer the model was given (server-built JSON: menu/cart facts and guidance, no provider data).
    def result_json
      JSON.pretty_generate(parsed_result)
    rescue JSON::GeneratorError, TypeError
      invocation.result.to_s.truncate(2000)
    end

    private

    # Elapsed time since the last get_cart, as latency information only. Call #9 showed why it is not evidence of an
    # answer: the read-back and the submit came from one model completion, and the 12.9 s were the agent's own speech.
    def submit_elapsed
      return unless tool == "submit_order"

      previous = call_log.tool_invocations.where(tool_name: "get_cart", status: "ok").where(started_at: ...invocation.started_at).order(started_at: :desc).first
      return Observation.new(text: "no get_cart before this submit", warn: true) unless previous

      seconds = (invocation.started_at - previous.started_at).round(1)
      Observation.new(text: "#{seconds} s since the last get_cart (elapsed time only, includes the agent's speech; not evidence the caller answered)", warn: false)
    end

    # Shadow-mode turn evidence recorded at submit time (Voice::TurnEvidence). Observation only: nothing was refused.
    def submit_turn_evidence
      return unless tool == "submit_order"

      evidence = invocation.turn_evidence
      return [ shadow("turn evidence not recorded for this submit (recorded before shadow instrumentation, or replayed/unrecorded)", false) ] unless evidence.is_a?(Hash)

      case evidence["artifact_messages"]
      when "missing" then return [ shadow("turn evidence unavailable: the webhook carried no conversation history", true), gate_line(evidence) ]
      when "present" then nil
      else return [ shadow("turn evidence unavailable: the conversation history was unreadable", true), gate_line(evidence) ]
      end

      [ caller_turns_observation(evidence), after_submit_observation(evidence), completion_observation(evidence["completion"]), gate_line(evidence) ].compact
    end

    def shadow(text, warn) = Observation.new(text: text, warn: warn, icon: "◌")

    # What the server's confirmation gate did with this submit. Evidence schema 2 is enforced (OrderTaking#submit);
    # rows recorded with schema 1 were observed in shadow mode only.
    def gate_line(evidence)
      return shadow("confirmation gate: shadow only (observed, nothing refused)", false) unless evidence["mode"] == "enforced"
      return shadow("confirmation gate: submit refused (no caller turn after the read-back)", true) if code == "customer_confirmation_required"
      return shadow("confirmation gate: not reached (refused earlier as #{code || status})", false) unless status == "ok"
      return shadow("confirmation gate: not applied (the order was already submitted)", false) if parsed_result.is_a?(Hash) && parsed_result["already_submitted"]

      shadow("confirmation gate: passed (a caller turn followed the read-back)", false)
    end

    def caller_turns_observation(evidence)
      turns = evidence["caller_turns_since_last_get_cart"]
      return shadow("caller turns since the last get_cart result: n/a (no get_cart result in Vapi's history)", true) if turns.nil?

      shadow("caller turns since the last get_cart result: #{turns} (turn-taking only; not a yes)", turns.zero?)
    end

    def after_submit_observation(evidence)
      later = evidence["caller_turns_after_submit_request"].to_i
      return if later.zero?

      gap = evidence["ms_submit_request_to_next_caller_turn"]
      shadow("caller began speaking #{gap ? "#{(gap / 1000.0).round(2)} s " : ''}after the submit was requested (#{later} later turn#{'s' if later > 1}, not counted)", false)
    end

    def completion_observation(completion)
      return shadow("model completion: not identifiable in Vapi's history", false) unless completion.is_a?(Hash) && completion["found"]

      # speech_chars is not shown: Vapi's live history lags the spoken audio, so the count at submit time is unreliable.
      if completion["responds_to_get_cart_result"]
        shadow("same model completion answered the get_cart result and issued this submit: yes", true)
      else
        shadow("same model completion answered the get_cart result and issued this submit: no", false)
      end
    end

    # The server refused the submit because no caller turn followed the read-back: say so plainly, with the structural
    # evidence it was refused on. (The full guidance the model received is under "what the agent was told".)
    def confirmation_refused_summary(body)
      turns = invocation.turn_evidence.is_a?(Hash) ? invocation.turn_evidence["caller_turns_since_last_get_cart"] : nil
      basis = turns.nil? ? "no readable conversation history" : "#{turns} caller turn#{'s' unless turns == 1} since the last get_cart"
      "confirmation required · submit refused (#{basis}; nothing was submitted, v#{body.dig('error', 'cart_version')} kept)"
    end

    # An accepted add that leaves the same menu item on two cart lines.
    def second_line
      return unless tool == "add_to_cart" && status == "ok" && invocation.arguments.is_a?(Hash)

      name = item_name(invocation.arguments["menu_item_id"])
      lines = Array(parsed_result.is_a?(Hash) ? parsed_result["items"] : nil).count { |item| item["menu_item"] == name }
      Observation.new(text: "#{name} is now on #{lines} lines of the cart", warn: true) if lines > 1
    end

    def parsed_result
      @parsed_result ||= invocation.result.is_a?(String) ? JSON.parse(invocation.result) : invocation.result
    rescue JSON::ParserError
      nil
    end

    def add_summary(args)
      modifiers = Array(args["modifier_ids"]).filter_map { |id| MenuItemModifier.find_by(id: id)&.name || "modifier ##{id}" }
      [ "#{args['quantity'] || 1}× #{item_name(args['menu_item_id'])}", (modifiers.join(", ") if modifiers.any?),
        ("notes: #{args['notes'].to_s.length} chars" if args["notes"].present?) ].compact.join(" · ")
    end

    def submit_summary(args)
      [ args["fulfillment_type"], "cart_version #{args['cart_version']}", ("address given" if args["delivery_address"].present?),
        ("notes: #{args['notes'].to_s.length} chars" if args["notes"].present?) ].compact.join(" · ")
    end

    def submit_result(body)
      return "already submitted · nothing changed" if body["already_submitted"]

      "confirmed v#{body['cart_version']} · sms #{body['confirmation_sms']}"
    end

    def item_name(id)
      call_log.restaurant.menu_items.find_by(id: id)&.name || "item ##{id}"
    end

    # A cart line's name as the server told the agent at the time: from this call's own results (the line may be gone now).
    def line_name(id)
      name = call_log.tool_invocations.where(id: ..invocation.id).order(id: :desc).limit(25).lazy.filter_map do |row|
        body = row.result.is_a?(String) ? (JSON.parse(row.result) rescue nil) : row.result
        Array(body.is_a?(Hash) ? body["items"] : nil).find { |item| item["id"].to_s == id.to_s }&.fetch("menu_item", nil)
      end.first
      name ? "line #{id} (#{name})" : "line ##{id}"
    end

    def money(value) = value.is_a?(Numeric) ? format("$%.2f", value) : "–"
  end
end

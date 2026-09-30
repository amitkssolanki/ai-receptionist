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

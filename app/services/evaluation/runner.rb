module Evaluation
  # Runs a scenario through the real server path and reports claims, tool calls, mutations and the resulting order.
  # Each run happens inside a transaction that is rolled back: the database is left exactly as it was found.
  class Runner
    CLAIM_WINDOW = (-2.0..8.0).freeze # seconds around a claim; the console's heuristic uses the same window

    def self.run(scenario)
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        result = new(scenario).call
        raise ActiveRecord::Rollback
      end
      result
    end

    def self.run_all(scenarios = Scenarios.all) = scenarios.map { |scenario| run(scenario) }

    def initialize(scenario)
      @scenario = scenario
      @world = World.new(call_id: "eval-#{scenario.id}")
      @transcript = []
      @tool_times = {}
    end

    def call
      @scenario.events.sort_by(&:t).each { |event| event.kind == :say ? @transcript << event : run_tool(event) }
      CallLifecycle.finish(external_call_id: @world.call_log.external_call_id, transcript: nil, recording_url: nil)
      report
    end

    private

    def run_tool(event)
      args = event.args.respond_to?(:call) ? event.args.call(@world) : event.args
      @tool_times[event.tool_call_id] = event.t
      raw = Voice::ToolRunner.call(call_log: CallLog.find(@world.call_log.id), tool_call: { "id" => event.tool_call_id, "function" => { "name" => event.tool, "arguments" => args } })
      body = JSON.parse(raw)
      @world.last_read_back_version = body["cart_version"] if event.tool == "get_cart" && body["ok"]
    end

    def report
      call_log = CallLog.find(@world.call_log.id)
      order = call_log.order
      tool_calls = call_log.tool_invocations.order(:id).map { |row| tool_call_entry(row) }
      claims = @transcript.filter_map { |line| claim_entry(line, order, tool_calls) if line.role == "assistant" && ClaimDetector.claim?(line.text) }

      {
        "id" => @scenario.id, "title" => @scenario.title, "purpose" => @scenario.purpose,
        "claims" => claims, "tool_calls" => tool_calls,
        "final_order" => final_order(order),
        "invariants" => invariants(order, call_log),
        "summary" => {
          "assistant_claims" => claims.size,
          "claims_not_reflected_in_server_order" => claims.count { |c| c["state_backed"] == false },
          "claims_flagged_by_console_window" => claims.count { |c| c["window_backed"] == false },
          "claims_indeterminate" => claims.count { |c| c["state_backed"].nil? },
          "tool_calls_received" => tool_calls.size,
          "tool_calls_that_mutated_the_cart" => tool_calls.count { |t| t["mutated_cart"] },
          "tool_calls_refused" => tool_calls.count { |t| t["status"] != "ok" },
          "duplicate_deliveries_absorbed" => tool_calls.sum { |t| t["replay_count"] },
          "final_order_status" => order&.status || "none", "final_cart_version" => order&.cart_version || 0
        }
      }
    end

    def tool_call_entry(row)
      {
        "tool" => row.tool_name, "tool_call_id" => row.tool_call_id, "t" => @tool_times[row.tool_call_id], "status" => row.status,
        "error_code" => row.error_code, "cart_version_before" => row.cart_version_before, "cart_version_after" => row.cart_version_after,
        "mutated_cart" => row.status == "ok" && row.cart_version_before != row.cart_version_after,
        "server_ms" => row.duration_ms, "replay_count" => row.replay_count
      }
    end

    def claim_entry(line, order, tool_calls)
      kind = ClaimDetector.kind(line.text)
      claimed_items = @world.item_names.select { |name| line.text.downcase.include?(name.downcase) }
      window = (line.t + CLAIM_WINDOW.begin)..(line.t + CLAIM_WINDOW.end)
      window_backed = tool_calls.any? { |t| t["mutated_cart"] && window.cover?(t["t"]) }
      in_order = order ? order.order_items.includes(:menu_item).map { |i| i.menu_item.name } : []

      state_backed =
        if claimed_items.empty? then nil
        elsif kind == "remove" then claimed_items.none? { |n| in_order.include?(n) }
        else claimed_items.all? { |n| in_order.include?(n) }
        end

      { "t" => line.t, "kind" => kind, "text" => line.text, "items_mentioned" => claimed_items,
        "window_backed" => window_backed, "state_backed" => state_backed,
        "missing_from_server_order" => (kind == "remove" ? claimed_items & in_order : claimed_items - in_order) }
    end

    def final_order(order)
      return nil unless order

      { "status" => order.status, "cart_version" => order.cart_version, "read_back_version" => order.read_back_version, "total" => order.total_cents / 100.0,
        "lines" => order.order_items.includes(:menu_item).order(:id).map { |i| { "quantity" => i.quantity, "item" => i.menu_item.name, "modifiers" => i.selected_modifiers.map { |m| m["name"] } } } }
    end

    # Two properties that must hold however badly the scripted assistant behaves.
    def invariants(order, call_log)
      added = call_log.tool_invocations.where(tool_name: "add_to_cart", status: "ok").filter_map { |r| @world.restaurant.menu_items.find_by(id: r.arguments["menu_item_id"])&.name }
      lines = order ? order.order_items.includes(:menu_item).map { |i| i.menu_item.name } : []
      confirmed = order&.confirmed? || order&.preparing?
      submit_ok = call_log.tool_invocations.where(tool_name: "submit_order", status: "ok").any? { |r| r.arguments["cart_version"] == order&.cart_version && order.read_back_version == order.cart_version }

      { "every_order_line_came_from_an_accepted_add_to_cart" => (lines - added).empty?,
        "confirmed_only_at_the_read_back_version" => confirmed ? submit_ok : nil }
    end
  end
end

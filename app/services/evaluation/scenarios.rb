module Evaluation
  # The scenario set. Every conversation prefix up to the claim is VERBATIM from real call #7 (the Phase 0 recording,
  # times in seconds since the call started); what follows the claim is the deliberate variation.
  module Scenarios
    TIMELINE = Rails.root.join("test/fixtures/files/baseline/call7/timeline.json")
    CLAIM_T = 112.5 # "Great. I'll add garlic knots..." in the recording

    module_function

    def all
      [ call7_verbatim, call7_adapted, control_no_claim, claim_then_accepted_add, claim_then_rejected_add, claim_tool_arrives_late,
        two_items_claimed_one_added, remove_claimed_without_tool, change_claimed_and_done, submit_without_read_back,
        stale_submit_after_change, late_duplicate_get_cart, duplicate_claimed_add, claim_after_confirmation, premature_submit_then_answered ]
    end

    # --- the recording ---

    def recorded
      @recorded ||= JSON.parse(TIMELINE.read)
    end

    def menu_snapshot
      @menu_snapshot ||= JSON.parse(World::SNAPSHOT.read)["menu_reference"]
    end

    # Recorded conversation lines (verbatim) whose time falls in [from, to).
    def lines(from: 0, to: Float::INFINITY)
      recorded.select { |r| %w[bot user].include?(r["role"]) && r["t"] >= from && r["t"] < to }
              .map { |r| Evaluation.say(r["t"], r["role"] == "bot" ? "assistant" : "user", r["message"]) }
    end

    def recorded_tool(name)
      row = recorded.find { |r| r["role"] == "tool_calls" && r["tool_calls"].any? { |c| c["name"] == name } }
      call = row["tool_calls"].find { |c| c["name"] == name }
      [ row["t"], call["id"], JSON.parse(call["arguments"]) ]
    end

    # The recorded add_to_cart used dev-database ids; translate them to the ids of this world by NAME.
    def recorded_add_args(args)
      lambda do |w|
        item = menu_snapshot["items"].find { |i| i["id"] == args["menu_item_id"] }
        modifiers = Array(args["modifier_ids"]).map { |id| menu_snapshot["modifiers"].find { |m| m["id"] == id } }
        args.merge("menu_item_id" => w.item_id(item["name"]), "modifier_ids" => modifiers.map { |m| w.modifier_id(item["name"], m["name"]) })
      end
    end

    def read_back_version = ->(w) { w.last_read_back_version }

    def recorded_events(adapted:, through: Float::INFINITY)
      events = lines(to: through)
      t, id, = recorded_tool("get_menu")
      events << Evaluation.tool(t, id, "get_menu")
      t, id, args = recorded_tool("add_to_cart")
      events << Evaluation.tool(t, id, "add_to_cart", recorded_add_args(args))
      t, id, = recorded_tool("get_cart")
      events << Evaluation.tool(t, id, "get_cart")
      t, id, args = recorded_tool("submit_order")
      events << Evaluation.tool(t, id, "submit_order", adapted ? ->(w) { args.merge("cart_version" => w.last_read_back_version) } : args)
      events.select { |e| e.t < through }
    end

    # --- scenarios ---

    def call7_verbatim
      Scenario.new("call7_verbatim", "Call #7 exactly as recorded",
                   "The real failure. The agent says it will add garlic knots; it never calls add_to_cart. (The recorded submit_order has no cart_version, so today's server refuses it: the contract changed after this call.)",
                   recorded_events(adapted: false))
    end

    def call7_adapted
      Scenario.new("call7_adapted", "Call #7 with the cart_version from the read-back supplied",
                   "What the server would have confirmed: $16, Margherita only. The claim about garlic knots is never reflected; the server does not treat it as proof.",
                   recorded_events(adapted: true))
    end

    def control_no_claim
      Scenario.new("control_no_claim", "Control: same order, no claims",
                   "A clean conversation must produce zero claims and zero mismatches (the heuristic must not cry wolf).",
                   prefix_to(98.3) + [ say(102, "assistant", "Anything else, or should I read back your order?"), say(124, "user", "Read back my order."),
                                        Evaluation.tool(131.5, "c1", "get_cart"), say(133, "assistant", "I've got one Margherita pizza with extra cheese for pickup, total $16."),
                                        say(137, "user", "Yes, that's right."),
                                        Evaluation.tool(142, "s1", "submit_order", ->(w) { { "fulfillment_type" => "pickup", "cart_version" => w.last_read_back_version } }) ])
    end

    def claim_then_accepted_add
      Scenario.new("claim_then_accepted_add", "Claim, then the tool really adds the knots",
                   "The healthy path: claim at t=112.5, add_to_cart at 114 accepted. Claim backed by both the window and the server order.",
                   claim_base + [ add_knots(114, "k1"), Evaluation.tool(131.5, "c1", "get_cart"), say(136.5, "user", "Yes."),
                                   Evaluation.tool(142, "s1", "submit_order", ->(w) { { "fulfillment_type" => "pickup", "cart_version" => w.last_read_back_version } }) ])
    end

    def claim_then_rejected_add
      Scenario.new("claim_then_rejected_add", "Claim, and a tool call arrives - but the server rejects it",
                   "The server RECEIVED add_to_cart but refused it (a modifier that belongs to another item). A tool call is not a mutation: the claim stays unbacked.",
                   claim_base + [ Evaluation.tool(114, "k1", "add_to_cart", ->(w) { { "menu_item_id" => w.item_id("Garlic Knots"), "modifier_ids" => [ w.modifier_id("Margherita Pizza", "Extra cheese") ] } }) ])
    end

    def claim_tool_arrives_late
      Scenario.new("claim_tool_arrives_late", "Claim, and the tool call comes 12.5 s later",
                   "Documents the heuristic's false positive: the add is accepted, but outside the +8 s window, so the console flags the claim although the server order does contain the knots.",
                   claim_base + [ add_knots(125, "k1") ])
    end

    def two_items_claimed_one_added
      Scenario.new("two_items_claimed_one_added", "Claims knots AND fries, adds only knots",
                   "Documents the heuristic's false negative: a cart change backs the claim in time, but the server order lacks the fries. The state comparison catches it.",
                   prefix_to(112) + [ say(112.5, "assistant", "Great. I'll add garlic knots and French fries."), add_knots(114, "k1") ])
    end

    def remove_claimed_without_tool
      Scenario.new("remove_claimed_without_tool", "Claims to have removed the pizza, calls no tool",
                   "A removal claim with no remove_cart_item call: the pizza is still in the server order.",
                   prefix_to(98.3) + [ say(105, "assistant", "I've removed the Margherita pizza from your order.") ])
    end

    def change_claimed_and_done
      Scenario.new("change_claimed_and_done", "Claims a quantity change and the tool makes it",
                   "A change claim that IS backed: update_cart_item_quantity accepted right after.",
                   prefix_to(98.3) + [ say(105, "assistant", "I've changed that to two."),
                                        Evaluation.tool(106, "u1", "update_cart_item_quantity", ->(w) { { "order_item_id" => w.first_line_id, "quantity" => 2 } }) ])
    end

    def submit_without_read_back
      Scenario.new("submit_without_read_back", "Claims, adds, then submits without ever reading the cart back",
                   "Skipping get_cart: the server refuses the submit (readback_required); the order is never confirmed.",
                   claim_base + [ add_knots(114, "k1"), Evaluation.tool(120, "s1", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 }) ])
    end

    def stale_submit_after_change
      Scenario.new("stale_submit_after_change", "Read back at v1, change the cart, submit the old version",
                   "The model read back v1, the cart moved to v2, and the model submits v1 (then v2 without re-reading): both refused.",
                   prefix_to(98.3) + [ Evaluation.tool(100, "c1", "get_cart"), add_knots(114, "k1"),
                                        Evaluation.tool(120, "s1", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 1 }),
                                        Evaluation.tool(121, "s2", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 }) ])
    end

    def late_duplicate_get_cart
      Scenario.new("late_duplicate_get_cart", "A late duplicate of an old get_cart tries to refresh the read-back",
                   "Replaying get_cart returns the STORED v1 result and does not make the stale read-back current: the later submit of v2 is refused.",
                   prefix_to(98.3) + [ Evaluation.tool(100, "c1", "get_cart"), add_knots(114, "k1"), Evaluation.tool(118, "c1", "get_cart"),
                                        Evaluation.tool(120, "s1", "submit_order", { "fulfillment_type" => "pickup", "cart_version" => 2 }) ])
    end

    def duplicate_claimed_add
      Scenario.new("duplicate_claimed_add", "The claimed add is delivered twice with the same tool call id",
                   "One execution, one knots, cart_version moves once, replay_count 1.",
                   claim_base + [ add_knots(114, "k1"), add_knots(114.4, "k1") ])
    end

    def claim_after_confirmation
      Scenario.new("claim_after_confirmation", "After the order is confirmed the agent claims another add",
                   "The confirmed order is locked: the late add is refused (order_already_submitted), the claim is unbacked, the order is unchanged.",
                   prefix_to(98.3) + [ Evaluation.tool(100, "c1", "get_cart"), say(102, "user", "Yes, that's right."),
                                        Evaluation.tool(105, "s1", "submit_order", ->(w) { { "fulfillment_type" => "pickup", "cart_version" => w.last_read_back_version } }),
                                        say(110, "assistant", "I've added garlic knots to your order."), add_knots(111, "k1") ])
    end

    # The pattern seen in live calls #1 and #6 (Vapi/DB calls #8, #13): the model submits in the same breath as
    # the read-back, before the caller can answer. The server's confirmation gate refuses it; after the caller answers,
    # the same submit is accepted.
    def premature_submit_then_answered
      submit = ->(w) { { "fulfillment_type" => "pickup", "cart_version" => w.last_read_back_version } }
      Scenario.new("premature_submit_then_answered", "Read-back and submit in one breath, then the caller answers",
                   "Live calls #1 and #6 submitted before the caller answered. The server refuses that submit (customer_confirmation_required: no caller turn after the read-back); after the caller's answer the submit is accepted.",
                   prefix_to(98.3) + [ say(102, "assistant", "Anything else, or should I read back your order?"), say(124, "user", "Read back my order."),
                                        Evaluation.tool(131.5, "c1", "get_cart"),
                                        say(132, "assistant", "One Margherita pizza with extra cheese. Total sixteen dollars. Did I get that right?"),
                                        Evaluation.tool(132.5, "s1", "submit_order", submit), say(136.5, "user", "Yes, that's right."),
                                        Evaluation.tool(138, "s2", "submit_order", submit) ])
    end

    # --- building blocks ---

    # Recorded conversation and tool calls before the first add (verbatim), cut at `before`.
    def prefix_to(before)
      lines(to: 97).select { |l| l.t < before } + [ recorded_events(adapted: true).find { |e| e.tool == "get_menu" },
                                                     recorded_events(adapted: true).find { |e| e.tool == "add_to_cart" } ]
    end

    # Everything recorded up to and including the claim line.
    def claim_base = lines(to: CLAIM_T + 0.01) + recorded_events(adapted: true).select { |e| %w[get_menu add_to_cart].include?(e.tool) && e.t < CLAIM_T }

    def add_knots(t, id) = Evaluation.tool(t, id, "add_to_cart", ->(w) { { "menu_item_id" => w.item_id("Garlic Knots"), "quantity" => 1 } })

    def say(t, role, text) = Evaluation.say(t, role, text)
  end
end

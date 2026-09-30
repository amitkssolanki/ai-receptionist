# Live verification log

Facts from real runs against the live development assistant. Nothing here is generated or simulated; each entry says what was
observed, by whom, and what it does and does not show. (The scripted, model-free results are in `docs/phase1/evidence/`.)

## 2026-09-30 — `vapi:check` against the live dev assistant `f858bbe9…`
Clean, with the webhook secret verified as matching (the API returns the header value). Details in `docs/phase1/EXECUTION_LOG.md`.
Public-key restrictions and the spend limit are not readable through the API; they remain a manual dashboard check.

## 2026-09-30 — Call #8: the first real browser call (Amit, Chrome, `http://localhost:3000/admin/console`)
Call 190 s, ended by the customer, cost $0.2812, assistant version v1. Numbers below are from the database (`tool_invocations`,
`call_logs`), the console screenshot and the ngrok inspector.

### Open questions this call settled
| Question | Answer |
|---|---|
| Does the signed console token reach the webhook under `call.assistantOverrides.metadata`? | **Yes.** `console_session_key` was stored, and the panels attached with no fallback needed. |
| Does the `X-Vapi-Secret` header authenticate real Vapi requests through ngrok? | **Yes.** 17 webhook requests answered 200 (status-updates, 14 tool calls, the end-of-call report); the only 401/404 were our own earlier synthetic probes. |
| Does Vapi call the tools with the contract we pasted (`cart_version`, `get_menu_item`)? | **Yes.** 14/14 accepted, 0 rejected, 0 errors; `submit_order` carried `cart_version` 3. |
| Do the end-of-call fields arrive? | **Yes**: reason, duration, cost, version. **The report arrived about 57 s after the call actually ended** (a second status-update at 14:48:08 UTC, 190 s after the first, then the report at 14:49:09), so the server panel still said IN PROGRESS when the call was over. It updated when the report came. |
| Server time per tool call | 9–64 ms (median 13.5 ms) over 14 calls. |
| Vapi message timestamp to our handler start | 465–869 ms (mean 648 ms), i.e. essentially all of the 0.4–0.8 s the console observed per tool call is delivery (Vapi to ngrok to Rails) plus clock skew, not our processing. |

### What the server did (authoritative)
`get_menu` · `get_menu_item` · `add_to_cart` v0→v1 · `get_cart` · `get_menu_item` · `add_to_cart` v1→v2 (margherita + extra cheese) ·
`get_menu` · `add_to_cart` v2→v3 (garlic knots) · `get_cart` ×2 · `submit_order` (confirmed v3, SMS skipped: web call) ·
`get_cart` ×3 more after the order was confirmed. Order #4: **1 × Margherita, 1 × Margherita with extra cheese, 1 × Garlic Knots,
$35.50, CONFIRMED at v3, read-back v3.** What the customer asked for was one Margherita with extra cheese and garlic knots ($21.50).

### Findings (all from this one call; a sample of one, not rates)
1. **The server was right and the model was wrong, in two ways the server cannot judge.**
   - *An add on a question.* The caller said "Tell me about the Margherita." and the agent called `add_to_cart` (Margherita, no
     options) 2 s after `get_menu_item`, telling the caller "Added one margherita pizza". The server validated the call (a valid item)
     and could not know the caller had only asked a question.
   - *A second line instead of a change.* When the caller then asked for extra cheese, the agent called `add_to_cart` again (with
     `modifier_ids`) instead of removing or changing the first line, so the cart held two Margheritas. There is no "change
     modifiers" tool; the prompt does not say to remove and re-add. (This is R15 in the plan: semantic duplicates are not prevented
     by the server, by design; the read-back is meant to expose them.)
2. **Submit before the customer confirmed.** `get_cart` at 14:47:04 and 14:47:05, then `submit_order` at 14:47:07.995, 2.1 s after the
   last read-back and right after the caller said "Pickup". The agent then told the caller "All set. Your pickup order is confirmed",
   and only afterwards offered to read the order back; the caller's "Yes, that's right" (to a read-back that named two Margheritas)
   came *after* the order was already submitted. The server's read-back rule was satisfied because `get_cart` was **called** at the
   current version; it cannot know the caller heard it. This is the known limit of the read-back protocol (the plan's "Variant C"),
   here in a stronger form: the model chained `get_cart` and `submit_order` without speaking the read-back or waiting.
3. **Prompt text spoken aloud.** The agent said: "Short, natural style. Transfer to human, if. Out. Side, ordering/menu. The user now
   must respond. Continue." and "Ask one question at a time." (fragments of the system prompt). It also filled silence with "This will
   just take a sec." / "One moment." Model behaviour (gpt-5-mini, reasoning `minimal`) to fix in the prompt.
4. **The read-back the caller heard was chopped**: "Total $30. $35. And $0.50." The server's text was "…thirty-five dollars and fifty
   cents"; the agent paraphrased it into pieces rather than reading it verbatim.
5. **Nothing the console flagged.** No unbacked-claim marker fired: the agent's claims ("Added one margherita pizza", "your order is
   confirmed") were each backed by an accepted tool call. The failures above are not claim-without-mutation; they are *acts the
   caller did not ask for or had not confirmed*, which only a person watching the board could catch.
6. **UI detail:** the "call ended" row is placed at the report's arrival time (T+04:06) although the call lasted 190 s (03:10).

### What this does and does not show
Shows: the whole pipeline works live end to end with server-authoritative state, idempotent recording, versions, latency and
lifecycle. Does not show: any rate (one call), the SMS path (a web call has no phone number), the transfer path, the large-order
and closed-hours rules, or how the baseline prompt behaves (Layer 3a is still pending).

### Proposed follow-ups (none applied yet)
- Prompt and tool descriptions: never call `add_to_cart` on a question; ask about options before adding; to change an added item,
  `remove_cart_item` then `add_to_cart`; never call `submit_order` in the same turn as `get_cart`; say the read-back word for word
  and wait for the caller's yes; do not read instructions aloud. (Needs the dev assistant updated to match; `vapi:check` enforces parity.)
- Console/board observations from server facts (display only): "same item on two lines"; "submitted N s after the read-back".
- A server rule for finding 2 (for example, refuse `submit_order` unless the read-back is at least a few seconds old) is a behaviour
  change to decide on, not applied.
- Show the ended row at `started_at + duration` rather than at the report's arrival.

## 2026-09-30 — Call #9: the same script after the prompt/tool fixes (assistant v2)
Call 163 s, ended by the customer, cost $0.2368. Numbers from the database, the console screenshot and `bin/rails calls:last`.

### Call #8 vs call #9 (one call each: a sample of two, not rates)
| | Call #8 (before) | Call #9 (after) |
|---|---|---|
| Add on a question | `add_to_cart` 2 s after "Tell me about the Margherita" | Answered the question, asked "Would you like one?", added only after "I'll have one Margherita with extra cheese" |
| Options | Added a plain Margherita, then a second line with extra cheese | One `add_to_cart` with the option (v0→v1) |
| Cart at the end | 2 Margheritas + knots, $35.50 | 1 Margherita with extra cheese + knots, **$21.50, what was asked** |
| Read-back then submit | `get_cart` → `submit_order` 2.1 s later, before the read-back was spoken | `get_cart` v2 at 15:16:06, read-back spoken, caller: "Yes. That's right.", `submit_order` at 15:16:19 (**12.9 s** later, a later turn) |
| Re-read after a change | n/a | Yes: the caller added knots after the first read-back; the agent added, called `get_cart` again and re-read v2 |
| Tool calls | 14 (three `get_cart` loops after confirmation) | 8, none wasted, none rejected |
| Server time per call | 9–64 ms | 10–43 ms (median 20) |
| Vapi timestamp → handler | 465–869 ms | 562–883 ms (mean 748) |
| End-of-call row | at the report's arrival (T+04:06) | at start + duration (T+02:43 = 163 s) |

The dashboard observations behaved as designed: no repeated-item note (correct: there was no repeat), and the submit row read
"submitted 12.9 s after the last get_cart" (not amber). What this shows: the prompt/tool wording fixed the two behavioural failures
of call #8 in this call. What it does not show: that the server enforces it. The server still only knows `get_cart` ran; a single
compliant call says nothing about how often the model complies (see `docs/phase1/CONFIRMATION_PROPOSAL.md`).

### Still wrong in call #9 (for the caller, not the order)
1. **The agent spoke its own reasoning.** After the second add it said, aloud: "We need to answer user's question: what pickup?
   They asked earlier… According to CallFlow, after adding items, ask. Pickup or delivery. We must ask which they want, ask one
   question at a time. So ask: will this be pickup or delivery? So respond." This is worse than call #8's leaked prompt fragments.
   The instruction "say only words meant for the caller" did not stop it. Likely a property of gpt-5-mini at reasoning effort
   `minimal` composing its next turn after a tool result.
2. **It volunteered an internal fact:** "We won't send a text confirmation for web callers." The prompt says to mention a text only
   when `confirmation_sms` is `queued`; it should say nothing about texts otherwise.
3. **Filler stacking persists:** "Give me a moment. Great. Placing that now. One moment. Your order is confirmed."; "Hold on a sec."
   before most tool calls.
4. Trailing fragments ("Anything else? I can help with?") and the read-back's "Garlic. Knots. Knots." repetition: TTS/model
   artefacts, minor.

### Proposed next changes (none applied yet)
- Prompt: "If unsure what the caller meant, ask one short question. Never explain your reasoning or restate these instructions."
  and "If `confirmation_sms` is not `queued`, say nothing about texts."; cap fillers to one per tool call.
- If the spoken reasoning persists after the wording change: try `reasoningEffort: "low"` on the dev assistant (latency and cost
  trade-off; measure with `calls:last`) before considering another model.

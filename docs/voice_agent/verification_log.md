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
| Read-back then submit | `get_cart` → `submit_order` 2.1 s later, before the read-back was spoken | `get_cart` v2 at 15:16:06, read-back spoken, caller: "Yes. That's right.", `submit_order` at 15:16:19 (**12.9 s** later, a later turn) **— corrected below: the same model completion, 0 caller turns; the 12.9 s was the agent's own speech** |
| Re-read after a change | n/a | Yes: the caller added knots after the first read-back; the agent added, called `get_cart` again and re-read v2 |
| Tool calls | 14 (three `get_cart` loops after confirmation) | 8, none wasted, none rejected |
| Server time per call | 9–64 ms | 10–43 ms (median 20) |
| Vapi timestamp → handler | 465–869 ms | 562–883 ms (mean 748) |
| End-of-call row | at the report's arrival (T+04:06) | at start + duration (T+02:43 = 163 s) |

The dashboard observations behaved as designed: no repeated-item note (correct: there was no repeat), and the submit row read
"submitted 12.9 s after the last get_cart" (not amber). What this shows: the prompt/tool wording fixed the two behavioural failures
of call #8 in this call. What it does not show: that the server enforces it. The server still only knows `get_cart` ran; a single
compliant call says nothing about how often the model complies (see `docs/phase1/CONFIRMATION_PROPOSAL.md`).
**Correction (later the same day, see "Correction: call #9 did not wait for the caller" below): the read-back/submit row above is
wrong. Only the add-on-a-question and duplicate-line fixes held in call #9; the submit ordering did not.**

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

## 2026-09-30 — Correction: call #9 did not wait for the caller
Source: Vapi's stored record of calls #8 and #9 (`GET /call/{id}`, read-only) and the live `submit_order` webhooks of both calls,
still held by the local ngrok inspector (structure-only copies: `test/fixtures/files/vapi/live_submit_webhook_call{8,9}.json`).

- In call #9 one model completion produced the spoken read-back ("…Total $21.50. Did I get that right?") **and** the
  `submit_order` call. Vapi speaks a completion's text and then runs its tool call, so `submit_order` was requested at 130.4 s from
  call start, as the read-back finished playing; the caller's "Yes. That's right." began **104 ms after** the request. There was
  **no caller utterance** between the last `get_cart` result and the submit. The 12.9 s between `get_cart` and `submit_order` was
  the agent's own speech, not time the caller had to answer.
- Call #8 had the same shape: 0 caller utterances between the last `get_cart` result (131.0 s) and `submit_order` (131.8 s); the
  completion that submitted spoke 44 characters of filler.
- So the submit-ordering failure occurred in **both** live calls (2 of 2). The call #9 table row above and the dashboard's
  "submitted N s after the last get_cart" observation were misleading; the observation has been replaced (next entry).
- Vapi billed `reasoningTokens = 0` for both calls (reasoning effort `minimal`); the spoken reasoning in call #9 sits in the
  model's ordinary `content`. Recorded here as a fact for the reasoning-effort experiment, not acted on.

## 2026-09-30 — Shadow turn evidence at submit (instrumentation, not enforcement)
Code: `Voice::TurnEvidence`, stored per `submit_order` in `tool_invocations.turn_evidence`, shown on the console's submit row
(◌ lines) and in `bin/rails calls:last`. **Nothing is refused, delayed or changed**: the submit runs exactly as before.

**What the live `tool-calls` webhook carries** (verified on calls #8 and #9): `message.artifact` with `messages`,
`messagesOpenAIFormatted`, `variableValues`, `variables`.
- `messages`: one entry per event, in order. `system` / `bot` / `user` entries carry `message`, `time` (epoch ms), `endTime`,
  `secondsFromStart`, `duration`; `tool_calls` entries carry `time` and `toolCalls[{id, function{name}}]`; `tool_call_result`
  entries carry `time`, `name`, `toolCallId`, `result`. **The in-flight submit is already in the list** (its `toolCalls[].id`
  equals the webhook's `toolCallList[].id`), and **caller speech that began after the submit request can also be in it** (call #9:
  the "yes" is the entry after the submit).
- `messagesOpenAIFormatted`: the model's view; one `assistant` entry per model completion (`content` = what it said, `tool_calls`),
  `tool` entries (`tool_call_id`), `user` entries. Completion boundaries are visible only here.

**How it is derived (by position, stateless, per submit):**
- *Caller turns since the last get_cart*: `user` entries in `messages` strictly after the last `tool_call_result` named `get_cart`
  and strictly before the submit's own `tool_calls` entry. Speech during the `get_cart` request is not counted; `user` entries
  after the submit request are reported separately (`caller_turns_after_submit_request`) and never counted.
- *Same completion*: in `messagesOpenAIFormatted`, the `assistant` entry whose `tool_calls` contain this submit's id; it "answered
  the get_cart result" when the entry immediately before it is the `tool` message for a `get_cart` call (no caller turn, no other
  tool result in between). Its speech is recorded as a character count only.
- Also stored: history present / missing / malformed, message count, the last `get_cart` tool-call id, millisecond gaps
  (get_cart result → submit request, submit request → next caller turn), and anomaly flags. **No text is stored.**

**Applied to the real payloads** (tests `test/services/voice/turn_evidence_test.rb`): call #9 → 0 caller turns, 1 later turn
starting 104 ms after the request, same completion (118 characters spoken); call #8 → 0 caller turns, same completion
(44 characters). Calls #8 and #9 themselves have no stored evidence (they predate the instrumentation); the console says so.

**Limits:** a caller turn is evidence of turn-taking, **not of a yes** (no classifier, by decision). The observation trusts the
order of Vapi's list and its speech-to-text; a caller who speaks during the read-back counts as a turn only if Vapi recorded that
utterance before the submit entry. Not yet seen live with this code: the next call (#3 in the owner's numbering) is the first.

## 2026-09-30 — Call #10: INVALID RUN (infrastructure failure, not a model-behaviour sample)
Intended as "Call #3" in the owner's numbering: the call #9 script, prompt, model and reasoning effort, with the new shadow turn
evidence. Call 76 s, ended by the customer, cost $0.0988, assistant v2. **No conclusion about model behaviour or turn evidence is
drawn from this call**, and it is not counted in any comparison. The experiment is to be re-run unchanged.

- **Immediate cause: a stale running server.** `bin/dev` had been running since 19:53; the `turn_evidence` migration was run at about
  21:04 from a separate process. The running server's column information predated the column, so every tool invocation's audit
  insert raised `ActiveModel::UnknownAttributeError (unknown attribute 'turn_evidence' for ToolInvocation)`.
- **Secondary defect: the "served unrecorded" fallback.** `get_menu` and both `get_menu_item` calls were served unrecorded as
  designed (hence the agent could describe the Margherita). The first `add_to_cart` created the order, the audit insert failed, the
  transaction rolled back, and the in-memory `CallLog` still held the rolled-back `order_id`; the fallback's `lock!` raised
  `Locking a record with unpersisted changes`, the request returned 500, the agent said "I'm having a technical problem", and no
  order was created. The fallback had never worked for a call's first cart change outside tests: the transactional test wrapper
  turns the runner's transactions into savepoints, which masked it. Fixed (the fallback and the unique-conflict retry now start
  again from the persisted call row); regression tests run with real transactions
  (`test/services/voice/tool_runner_unrecorded_fallback_test.rb`).
- **What the console showed, correctly:** four tool calls that Vapi reported (`get_menu`, `get_menu_item` ×2, `add_to_cart`) marked
  "⚠ no server record of this tool call was observed", an empty order board ("No cart yet"), server tools ✓0 ⛔0 ✖0, and the agent's
  "Adding that to your order right now." flagged as a claim not reflected in the server order.
- Server state: call #10 `abandoned`, 0 `tool_invocations`, no order.

## Call numbering (owner's live-test numbering vs Vapi/DB call ids)
| Owner's call | Vapi/DB call | Status |
|---|---|---|
| Call #1 | call #8 | valid |
| Call #2 | call #9 | valid |
| Call #3 | call #10 | **invalid infrastructure run** (see above) |
| Call #4 | call #11 | valid; did not reach a read-back or submit (below) |
| Call #5 | call #12 | valid; configured `low` (v3) but **runtime `minimal`**; stalled on the first turn (below) |
| Call #6 | call #13 | valid; configured `low` (v3) but **runtime `minimal`**; first live turn-evidence sample (below) |
| Call #7 | call #14 | valid; `minimal`; first call with the enforced gate and the aligned SMS prompt; gate passed (below) |
| Call #8 | the next live call | — |

## 2026-09-30 — Call #4 (Vapi/DB call #11): announced read-back never executed; no submit
Same script, prompt, tools, model and reasoning effort as Call #2, with the shadow turn evidence in place and `bin/dev` restarted
after the migration. Call 110 s, ended by the customer, cost $0.1373, assistant v2. Sources: the database (`tool_invocations`,
`orders`, `call_logs`), `bin/rails calls:last`, the console screenshot, and Vapi's stored call record (`GET /call/{id}`, read-only).

**What it established**
- **Infrastructure worked.** Rails received 4 tool-call webhooks (`get_menu`, `get_menu_item`, `add_to_cart`, `add_to_cart`),
  answered all 4 successfully and recorded all 4 (0 rejected, 0 errors); no errors in the server log.
- **The authoritative order was correct throughout:** order #7, 1 × Margherita Pizza with Extra cheese and 1 × Garlic Knots,
  $21.50, cart version 2 (v0→v1→v2). The call ended **abandoned**; the order is `abandoned`, read-back `not delivered`, never submitted.
- **No `get_cart` read-back was executed and no `submit_order` occurred**, so the turn-evidence instrumentation recorded **no live
  submit sample** from this call.

**Model behaviour observed (from Vapi's stored record; one call, not a rate)**
1. **An announced read-back with no tool call.** The agent said "Great. Pickup. Let me read the order back: One moment. Getting your
   cart." In the model's own history (`messagesOpenAIFormatted`) that completion has **no tool call**. No `get_cart` request reached
   Rails, and the agent was then silent until the caller ended the call (about 38 s later). Same shape as the Phase 0 baseline
   call #6 (announced "let me pull up the menu", no tool call), but here the assistant had all 8 tools attached.
2. **"Added…" spoken before the tool result existed**, for both cart additions: the completion that *requested* `add_to_cart` already
   contained the claim ("Give me a moment. Added 1 Margherita pizza, with extra cheese." → `add_to_cart`; "This will just take a sec.
   Added 1 garlic knots." → `add_to_cart`). Both adds then succeeded, so the claims happened to match the server order and the
   console's unbacked-claim heuristic (which looks for a cart change near the claim) correctly did not flag them. The prompt asks the
   agent to state a change only after the tool result confirms it.
3. It asked "pickup or delivery?" although the caller had already said "…for pickup"; the caller answered "Pickup?".
4. The caller's speech was captured well enough for the intended requests (speech-to-text: "Think about the margarita", "Add the
   garlic now"); the agent acted on them as intended. It pre-empted script step 5 by announcing the read-back itself.
5. Vapi billed `reasoningTokens = 0` again (`reasoningEffort: minimal`).

**What NOT to conclude from Call #4**
- It does **not** provide a turn-evidence result (no submit).
- It does **not** test whether `submit_order` comes before the caller's confirmation.
- It does **not** show that `reasoningEffort: minimal` caused these failures; no variable was changed, so there is nothing to
  attribute. It is one more failure observed under the unchanged current configuration, consistent with (not proof of) the
  hypothesis that the current runtime model/configuration has reliability problems.

**Experiment integrity:** unchanged from Call #2 — the Vapi assistant (dev, v2; `vapi:check` clean), runtime model
(`openai/gpt-5-mini`), reasoning effort (`minimal`), prompt, tools, SMS behaviour, filler behaviour and server-side order logic; the
turn-evidence implementation is unchanged since it was added (`0ed5ce4`); the only code change since Call #2 besides it is the
unrecorded-fallback fix (`7e4ccb5`), which acts only when a tool invocation cannot be recorded (not the case in this call).

**Next:** Call #5 with the exact same script and configuration, to obtain one current-configuration call that reaches
`submit_order` and so observe the live turn-evidence instrumentation.

## 2026-09-30 — Configuration change: reasoning effort `minimal` → `low` (dev assistant v2 → v3)
The single experiment variable changed after Call #4. One `PATCH /assistant/f858bbe9…` sent the assistant's complete current
`model` object with only `reasoningEffort` changed; a before/after comparison of the whole assistant (excluding `updatedAt` and
`latestVersion`) differs in `model.reasoningEffort` only (prompt and tools identical). The repository (`config/vapi/assistant.json`)
matches and `vapi:check` is clean. The frozen baseline assistant `8f2053ae…` was not touched. Everything else is unchanged:
runtime model `openai/gpt-5-mini`, prompt, tools, SMS, fillers, server-side order logic and the turn-evidence instrumentation.
Calls from Call #5 onward run on v3 (`low`); Calls #1–#4 (Vapi/DB calls #8–#11) ran on `minimal`.
**Correction (after Call #6): the runtime did not change.** Vapi's per-call logs show every OpenAI request in Calls #5 and #6 was sent with `reasoning_effort: "minimal"` although the assistant was configured `low` (entry "Reasoning-effort trial: configured `low`, runtime `minimal`" below). The setting was restored to `minimal` (v4).

## 2026-09-30 — Call #5 (Vapi/DB call #12): first call on `low`; stalled on the first turn
First call after the reasoning-effort change (dev assistant v3, `reasoningEffort: low`; recorded `assistant_version` v3). Same
script and everything else unchanged. Call 36 s (the browser showed 00:28 when it ended), ended by the customer, cost $0.0346.
Sources: the database, `bin/rails calls:last`, the console screenshot, and Vapi's stored call record (`GET /call/{id}`, read-only).

**What happened**
- The caller's first line (script step 1, "Hi, what pizzas do you have?") was transcribed as "Got it. What is it? First, do you
  have—" — garbled and cut off; the greeting had just finished ("…this is your. AI host. How can I help?").
- The agent answered "One moment." In the model's own history (`messagesOpenAIFormatted`) that completion has **no tool call**.
  Nothing reached Rails, and the agent was silent until the caller ended the call.
- Server: the call start, a status update and the end-of-call report were received and handled (the report arrived after the
  browser showed the call ended, as seen before); no tool calls, no errors, no order. Call #12 is `abandoned`, 0 tool invocations.
- Vapi reported `reasoningTokens = 0` for this call, as on `minimal`. With a single short completion this says little; if a full-length
  call on `low` also reports 0, whether Vapi applies the setting needs checking before the change can be evaluated.

**What NOT to conclude:** no turn-evidence result (no submit); nothing about submit ordering; nothing about the effect of `low` — one
very short call that failed on a garbled first utterance is not a comparison. It is another instance of the "announced, then no tool
call" behaviour already seen in Call #4 (and in baseline call #6), now under `low`.

**Experiment integrity:** only the planned variable differs from Calls #1–#4 (reasoning effort `low`, v3); the runtime model, prompt,
tools, SMS, fillers, server-side order logic and turn-evidence instrumentation are unchanged; the server needed no restart (no schema
change since the restart before Call #4).

## 2026-09-30 — Call #6 (Vapi/DB call #13): first live turn-evidence sample; premature submit again
Same script. Dev assistant v3 (configured `low`; runtime `minimal`, see the next entry). Call 114 s, ended by the customer, cost
$0.1648. Sources: the database (`tool_invocations`, including `turn_evidence`), `bin/rails calls:last`, the console screenshot, and
Vapi's stored call record (`GET /call/{id}`, read-only). Structure-only copies of both live submit webhooks:
`test/fixtures/files/vapi/live_submit_webhook_call13_{first,second}.json`.

- Server: 7 tool calls, all accepted: `get_menu`, `get_menu_item`, `add_to_cart` v0→v1 (Margherita + extra cheese), `add_to_cart`
  v1→v2 (garlic knots), `get_cart` (read-back v2), `submit_order` (confirmed v2), `submit_order` (already submitted, nothing changed).
  Order #8 CONFIRMED v2, $21.50.
- **First submit — premature.** Recorded turn evidence: history present (27 messages), **0 caller turns** since the last `get_cart`
  result, the submit issued by the completion that answered that result, 1,164 ms after it. The agent had started the read-back
  ("One Margherita pizza with extra cheese, and one garlic—") when the order was confirmed; "…Knots. Total $21.50. Did I get that
  right?" was spoken after the submit, and the caller's "Yes, that's right." came about 12 s after the order was already confirmed.
- **Second submit — after the caller's answer.** 1 caller turn since the last `get_cart` result, a later completion. The existing
  idempotency absorbed it: "already submitted · nothing changed" (the first live duplicate-submit absorption).
- The agent then said "We'll text you a confirmation when it's ready." although the first submit had returned
  `confirmation_sms: skipped_web_call` (no text is sent for a web call). The second such SMS misstatement (Call #2 volunteered
  "We won't send a text…").
- Vapi reported `reasoningTokens = 0` for the whole call.

## 2026-09-30 — Reasoning-effort trial: configured `low`, runtime `minimal`
- Source: Vapi's per-call logs (`GET /call/{id}/call-logs`, read-only), which record each OpenAI HTTP request Vapi made. The webhook
  payloads Vapi sent us during the same calls carry the **configured** assistant (`assistant.model.reasoningEffort: "low"`, version
  v3); the browser console sent no model override (only `clientMessages` and `metadata`).
- Observed requests: Call #2 (call #9, configured `minimal`): 38 × `reasoning_effort: "minimal"`. Call #5 (call #12, configured `low`):
  6 × `"minimal"`. Call #6 (call #13, configured `low`): 32 × `"minimal"`.
- Runtime by call: **Calls #1–#4: configured and runtime `minimal`. Calls #5–#6: configured `low`, observed runtime `minimal`.**
  Calls #5 and #6 are therefore additional `minimal` samples and give **no evidence about the effect of `low`**.
- `vapi:check` validates the configured assistant state, not the request Vapi actually sends downstream; it cannot detect this.
- The cause is not known (forcing, translation, a preset or some other override are all possible); no cause is asserted here.
- The dev assistant was restored to `reasoningEffort: minimal` (v3 → v4) with one `PATCH` of its complete `model` object; a before/after
  comparison of the whole assistant differs only in `model.reasoningEffort`; `config/vapi/assistant.json` matches; `vapi:check` clean.
  The frozen baseline assistant was not touched.

## 2026-09-30 — Turn evidence, first live results (Calls #1, #2 and #6)
- Every call that reached `submit_order` — Calls #1, #2 and #6 (Vapi/DB calls #8, #9 and #13) — submitted with **0 caller turns
  after the final `get_cart` result** (Calls #1 and #2 from Vapi's stored records and the live webhooks retained by the ngrok
  inspector; Call #6 recorded live by the instrumentation). A **3/3 observed premature-submit pattern** among calls that reached
  submission.
- In Call #6 the caller's confirmation arrived afterwards and the model issued a second submit, which the existing idempotency
  absorbed. The live caller-turn signal distinguished the two submits correctly (0 turns vs 1 turn); this validates the signal live.
- **Instrumentation limitation — `speech_chars`:** at submit time Vapi's webhook history can lag behind speech that later appears in
  the final call record (Call #6: 0 characters recorded at submit, while the final record places part of the read-back in that
  completion). `speech_chars` is unreliable and must not be used as an enforcement signal. The caller-turn count and the
  same-model-completion structure agreed between the live history and the final record and remain the useful structural evidence.

## 2026-09-30 — Confirmation gate enforced (not yet verified live)
From this commit the server refuses `submit_order` with `customer_confirmation_required` unless Vapi's history in the same webhook
shows at least one caller turn after the last `get_cart` result (missing or unreadable history fails closed). Checked against the
structure of the real submits: calls #1 and #2 and Call #6's first submit would have been refused; Call #6's second submit (after
the caller's "Yes, that's right.") would have been accepted. No live call has been made with the gate yet; the next one (Call #7)
is the first. Prompt, tools and the live assistant are unchanged.

## 2026-09-30 — Prompt SMS wording aligned (dev assistant v4 → v5)
The system prompt's SMS sentences now match what the model receives (`confirmation_sms: "queued"` only when a text was queued;
otherwise say nothing about texts); `skipped_web_call` / `already_handled` are no longer mentioned. Only `model.messages` changed on
the live dev assistant (verified before/after); runtime model, reasoning effort, tools, voice and transcriber are unchanged. The next
live call (Call #7) is the first with this prompt and with the enforced confirmation gate, so it changes two things relative to
Call #6; the gate is server-side and its effect is recorded per submit.

## 2026-09-30 — Call #7 (Vapi/DB call #14): the model waited; the gate passed
Same script (the caller also answered the agent's unscripted questions). Dev assistant v5: configured `minimal`, the enforced
confirmation gate and the aligned SMS prompt in place. Call 154 s, ended by the customer, cost $0.2145. Sources: the database
(`tool_invocations` incl. `turn_evidence`, `orders`, `call_logs`), `bin/rails calls:last`, the console screenshot, Vapi's stored call
record (`GET /call/{id}`) and per-call logs (`GET /call/{id}/call-logs`), and the live submit webhook retained by the ngrok inspector
(all read-only).

**What it established**
- Server: 6 tool calls, all accepted (`get_menu`, `get_menu_item`, `add_to_cart` v0→v1, `add_to_cart` v1→v2, `get_cart` read-back
  v2, `submit_order` confirmed v2); no duplicate submit. Final authoritative order #9: **1 × Margherita Pizza with Extra cheese,
  1 × Garlic Knots, $21.50, CONFIRMED at v2**, read-back v2.
- **Confirmation occurred correctly.** Recorded turn evidence: history present, **1 caller turn** after the last `get_cart` result,
  the submit issued by a **later model completion** (not the one that answered the `get_cart` result); the gate passed. Vapi's
  per-call log shows the model request that produced `submit_order` ended with the caller's "Yes. That's right." — the model had the
  caller's answer before it decided.
- "Added…" was spoken after the relevant `add_to_cart` result, in a separate completion (per the model inputs in Vapi's log).
- No SMS promise was made ("We'll have that ready for pickup"); the model received no SMS field (web call).
- Conversation requests: 19 OpenAI requests, all `reasoning_effort: "minimal"`; Vapi reported `reasoningTokens = 0`.

**Conversational-quality observations (not reliability failures):** the agent asked for a name ("John" was the caller's answer)
and for pickup notes, which the script does not include; it repeated its greeting in the middle of a menu answer ("…Thanks for
calling Taj Zeka, this is. Your AI host. How can I help?"); fillers ("Give me a moment", "This will just take a sec") remain.

**Evidence limitations**
- Vapi's history in the submit webhook split the caller's single reply into two entries around the submit: "Yes." before the submit
  request (stamped 0.15 s earlier) and "That's right." after it, while the model's input received the whole reply before it
  responded. The ordering was sufficient for this call; the timestamps in that history must not be read as precise speech timing.
- Vapi also made **two Azure OpenAI requests with `reasoning_effort: "low"`** during this call (full conversation and tools); their
  purpose and whether their output was used are not known. No cause is asserted. Together with Calls #5–#6, the configured value is
  not a reliable description of the runtime requests; reasoning effort remains unreliable as an experiment variable.
- One compliant call is not a rate. Among the calls that reached `submit_order`, 3 of 4 (Calls #1, #2, #6) submitted prematurely.
  The gate's **refusal** path has not yet occurred on a live call; it is covered by the replay of the recorded premature submits.

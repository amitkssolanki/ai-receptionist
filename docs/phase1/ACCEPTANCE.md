# Phase 1 acceptance report

> **Closeout note (2026-10-08):** this report is historical and kept as written. The branch `phase-1-reliability-console`
> was merged into `main` by PR #17 and deleted at the repository closeout; every commit it names is in `main`'s history.
> Current state: [docs/CURRENT_STATE.md](../CURRENT_STATE.md).

Status as of 2026-09-30, branch `phase-1-reliability-console`; first written after commit `1f1fb5b`, updated after
commit `1918acb` (criterion #18 and the README). Updated 2026-10-01 with the CI result and the #20 live call (see "Remaining acceptance work" at the end). Source of truth for the
criteria: `docs/phase1/PLAN.md` §14. Evidence: this repository, `docs/phase1/EXECUTION_LOG.md`, `docs/phase1/evidence/`,
`docs/voice_agent/verification_log.md`, and the verification run recorded in §11 below.

**Verdict: Phase 1 is complete against `PLAN.md` §14: 20 of 20 criteria are met** (as of 2026-10-01: #9 and #17 by the green
CI run, #20 by the scripted unclear-upsell live call, Call #9). The earlier verdict (17 of 20) is kept in the history of this file.
Criterion #18 was completed in the update (tests for the evidence builders and the Vapi client transport). Plan step 17 is partly done:
the README is rewritten; `docs/voice_agent/tools.md`, `vapi_setup.md` and parts of `local_setup.md` are still stale (§14).

---

## 1. What Phase 1 was meant to deliver

`PLAN.md`: "The model proposes. The server decides." A voice ordering agent (Vapi web call → `gpt-5-mini` → Rails tool API) in which
the server owns every business truth — cart, prices, `cart_version`, read-back, order status, lifecycle, SMS — and a browser test
console that shows the conversation (Vapi, not authoritative) next to what the server actually did (Rails, authoritative). Concretely:
the R01–R23 reliability rules from the Phase 0 baseline, a `ToolInvocation` audit trail, server-owned read-back with cart versioning,
idempotent tool execution, a live console, layered evaluation (contract tests, real-call replay), and live verification.

## 2. Acceptance criteria (`PLAN.md` §14)

| # | Criterion (abridged) | Status | Evidence |
|---|---|---|---|
| 1 | `OrderTaking`, `CallLifecycle`, `Voice::ToolRunner`, `MenuCatalog` exist; webhook controller has no business logic; generic adapter removed | **Complete** | `app/services/…`; `app/controllers/api/` holds only `vapi/`; no `api/voice` routes; controller is envelope-only (Step 2 commit `321e7b5`) |
| 2 | Every R01–R23 test re-asserted, kept as safe, or (R21/R22) retired with a reason; changes map to commits naming R-IDs | **Complete** | `test/baseline/reliability_characterization_test.rb` (R21/R22 skipped with `RETIRED_REASON`; R24 added for the gate); commit messages name R01–R14, R16–R24; R15 is unchanged by design (§3 of the plan: semantic duplicates are documented, not prevented) |
| 3 | Server owns read-back; submit requires the matching `cart_version` read-back | **Complete** | `OrderTaking#read_back` / `Readback`; `order_taking_cart_version_test.rb`; replay dangerous variants (`readback_required`, `cart_changed_since_readback`) |
| 4 | Submitted orders immutable by voice tools; admin cannot reopen | **Complete** | R03; `test/controllers/admin/orders_controller_test.rb` "an order cannot be reopened to pending"; `test/models/order_test.rb` |
| 5 | Duplicate submit returns the existing confirmation; SMS enqueued once | **Complete** | R02; `sms_guard_test.rb`; live: Call #6's second submit absorbed ("already submitted · nothing changed") |
| 6 | Duplicate toolCallId returns the stored result, incl. a simulated concurrent duplicate | **Complete** | R14; `tool_idempotency_test.rb`; `tool_runner_concurrency_test.rb` (real threads) |
| 7 | No tool response contains exception text or SQL | **Complete** | `tool_runner_test.rb` "no tool response ever contains exception text, SQL or class names"; `assert_no_leak` across the R-suite |
| 8 | Every tool execution persists a `ToolInvocation` | **Complete** | `tool_invocations_test.rb`; live calls #1, #2, #4–#7 (every server-received tool call recorded) |
| 9 | Layer 2 replays green **in CI**; `baseline:verify` reproduces 23/23 + 2/2 | **Complete** (2026-10-01) | Replays run in CI's full suite: [run 36760252445](https://github.com/amitkssolanki/ai-receptionist/actions/runs/36760252445), `test` job green (406 runs, 0 failures, 0 errors, 2 skips) at commit `627863a`. `baseline:verify` OK locally (25 runs); the CI workflow does not run it |
| 10 | `get_menu` ≤ 3 queries (constant when doubled), ≤ 1,600 bytes; benchmark recorded | **Complete** | `menu_performance_test.rb`; `EXECUTION_LOG.md` benchmark (median of 50, before vs after); 51 → 3 queries, 4,554 → 1,526 bytes |
| 11 | Console starts/stops a real Vapi web call and shows live partial/final transcripts | **Complete** | Live calls #1–#7 from `/admin/console` (screenshots, verification log); partial→final handling in `test/javascript/transcript.test.mjs` |
| 12 | Server rows live; pending rows resolve to server rows by toolCallId; board = DB | **Complete** | `console_broadcaster_test.rb`; `claims.test.mjs` (DOM ids match the server's); `console_backfill_test.rb` "what the state frame rebuilds equals what the live stream delivered"; live Call #3 showed unresolved pending rows when the server had no record (as designed) |
| 13 | Console resyncs after a Cable reconnect and in review mode | **Complete** | `console_backfill_test.rb` (missed events present after reload; state frame from the DB alone) |
| 14 | Secrets scan passes | **Complete** | `test/security/secrets_scan_test.rb`; `console_broadcaster_test.rb` "nothing sensitive is broadcast…"; `console_controller_test.rb` "only the public key and assistant id reach the browser" |
| 15 | `vapi:check` passes; baseline assistant unchanged | **Complete** | `vapi:check` OK (§11); baseline `8f2053ae…` `updatedAt` 2026-08-06T02:49:50.807Z, identical to Phase 0 |
| 16 | Webhook rejects missing/wrong secrets; no default outside `test` | **Complete** | `webhook_security_test.rb` (8 tests, incl. "the known old default is never accepted") |
| 17 | Tests, RuboCop, Brakeman, bundler-audit, importmap audit green; **CI green** | **Complete** (2026-10-01) | All local checks green (§11). CI green: [run 36760252445](https://github.com/amitkssolanki/ai-receptionist/actions/runs/36760252445) at commit `627863a` — `test`, `lint` (RuboCop), `scan_ruby` (Brakeman, bundler-audit), `scan_js` (importmap audit) all passed. One standalone run of the reliability suite had 1 failure that did not recur in 30 further standalone runs or in the full suites; the failing test was not captured and the cause is unknown |
| 18 | Coverage ≥ 65.7 % baseline; new service files ≥ 95 % | **Complete** (update) | The criterion has no exclusion for tooling, so all new `app/services` files count. Added tests of real behaviour (commit `161485a`): `evaluation.rb` 85.7 → 100 %, `evaluation/evidence.rb` 19.8 → 100 %, `vapi_config/client.rb` 80.0 → 100 %. Every `app/services` file is now ≥ 95 % (lowest `voice/turn_evidence.rb` 96.5 %); overall 93.5 % of `app/**/*.rb` (Phase 0: 65.7 %). Measured with stdlib `Coverage`, single process |
| 19 | Verification log records the outcome of every Phase 0 UNKNOWN touched | **Complete** (see note) | Recorded: metadata arrival (yes), webhook secret over ngrok (works), tool contract accepted, end-of-call fields (arrive, ~57 s late once), live assistant state, `PATCH` of `model` preserves other top-level fields, public-key restrictions/spend limit not API-readable. Note: tool-call-ID reuse on redelivery was **not observed** (no redelivery in 7 live calls; 0 duplicates absorbed from redelivery) — first recorded here. Not touched (deferred/out of scope): HMAC, JWT algorithm, web-call transfer, recording retention, `silenceTimeoutSeconds` |
| 20 | A live call shows a tool-backed order end to end, **and** the scripted unclear-upsell attempt is recorded | **Complete** (2026-10-01) | First half: Calls #2, #6, #7, #9. Scripted unclear-upsell attempt recorded: Call #9 (Vapi/DB call #16). Garlic knots offered; the reply was transcribed as "Should be—"; the model said "One moment." and nothing else — no clarifying question, no `add_to_cart`, no claim; order #10 confirmed at v1 without garlic knots. Attempt 1 (Call #8) did not reach the offer. See `verification_log.md` |

## 3. What live testing discovered

Nine live browser calls (owner's numbering; Vapi/DB ids in brackets): seven when this report was first written, #8 and #9 added for
criterion #20. Details: `docs/voice_agent/verification_log.md`. Corrected 2026-10-01 from Vapi's per-call model logs (Call #2).

| Call | Runtime reasoning | Outcome |
|---|---|---|
| #1 (#8) | `minimal` | Added on a question; duplicate Margherita line; **submit 2.1 s after `get_cart`, 0 caller turns**; wrong order $35.50 (server correct for what it was told) |
| #2 (#9) | `minimal` | Correct $21.50; **not premature** (corrected 2026-10-01): the model's input ended with the caller's "Yes. That's right.", but the webhook history stamps that turn 0.1 s after the submit, so the gate would refuse it (a false refusal); spoken reasoning; SMS fact volunteered |
| #3 (#10) | — | **Invalid run**: stale `bin/dev` after a migration + fallback locking bug; no conclusions |
| #4 (#11) | `minimal` | Announced "Getting your cart" with **no tool call**; went silent; abandoned; "Added…" spoken before the tool result |
| #5 (#12) | configured `low`, runtime `minimal` | Garbled first utterance; "One moment." with no tool call; stalled |
| #6 (#13) | configured `low`, runtime `minimal` | **Premature submit, 0 caller turns**, 1.2 s after the read-back fetch; second submit after the caller's yes absorbed; promised a text that was not sent |
| #7 (#14) | `minimal` (+2 Azure retries at `low` after OpenAI provider faults) | Correct $21.50; **1 caller turn** before the submit; model input ended with the caller's "Yes. That's right."; gate passed; no SMS promise |
| #8 (#15) | `minimal` | Criterion #20 attempt 1: "pizzas" misheard as "business"; the model repeated its greeting; no tool call; upsell not offered |
| #9 (#16) | `minimal` | Criterion #20: garlic knots offered; the unclear reply transcribed "Should be—"; the model said "One moment." and dropped it (no add, no claim); order $16.00 confirmed after the caller's yes; gate passed |

## 4–6. Failure modes and how each was addressed

| Failure mode | Seen in | Response | Kind of fix |
|---|---|---|---|
| Premature submit (before the caller answered) | Calls #1, #6 (2 of 4 that reached submit; corrected 2026-10-01, Call #2 was not premature) | Confirmation gate (§8) | **Server invariant** (deterministic) |
| Claim ≠ state ("I'll add garlic knots", no tool call) | Phase 0 call #7 | Server-owned read-back text and `cart_version`; console claim heuristic; evaluation probe | Server invariant + observability |
| Add on a question; duplicate line instead of edit | Call #1 | Prompt/tool wording; console "same item on two lines" observation | Prompt (probabilistic) + observability |
| Internal SMS state spoken to the caller | Calls #2, #6 | Model-facing result carries SMS only when queued; prompt aligned | Server contract + prompt |
| Announced action with no tool call | Calls #4, #5 (and Phase 0 call #6) | None server-side possible (no request reaches the server); visible in the console | **Open** |
| Spoken reasoning / prompt fragments | Calls #1, #2 | Prompt wording; reasoning-effort experiment inconclusive (runtime not controllable) | **Open** |
| Audit failure crashed the unrecorded fallback on the first cart change | Call #3 | Re-read the call row before fallback/retry; real-transaction regression tests | Server fix |
| Stale server after a migration | Call #3 | Runbook preflight: restart `bin/dev` after any migration | Procedure |

## 7. The role of the server-authoritative architecture

Every business fact lives in Rails and is changed only through `OrderTaking` under row locks: prices and totals come from the menu,
never from model arguments (R19); the cart has a version; the read-back text is generated by the server; submission requires the
read-back version and (now) a caller turn; submitted orders are immutable; every tool execution is an idempotent, recorded
`ToolInvocation`. The model's output is treated as a request. In the live calls the server was never wrong about what it was told:
Call #1's wrong order was exactly what the model asked for, and the console showed it.

## 8. The confirmation gate

**Invariant** (`OrderTaking#submit`, after the read-back and cart-version checks): an order is submitted only if Vapi's conversation
history in the same `tool-calls` webhook shows **at least one caller turn after the last `get_cart` result, positioned before the
submit's own entry**. Otherwise `submit_order` is refused with `customer_confirmation_required` (speakable guidance + current
`cart_version`); nothing is written and no SMS is queued. Missing, malformed or unreadable history fails closed. An already-submitted
order still answers idempotently. It is a turn-taking gate, not a "yes" detector; `speech_chars` is never used.

It was added because of the live evidence (at the time read as 3 of 3 premature submits; corrected on 2026-10-01 to Calls #1 and
#6, see §3) and is an architectural safeguard. **Call #7's compliant behaviour does not make it unnecessary.** Against the real
recorded submits: the premature submits of Calls #1 and #6 would each be refused, and Call #6's later submit after the caller's yes
would be accepted (`test/controllers/api/vapi/confirmation_gate_test.rb`, `live_submit_webhook_*.json`). Call #2's recorded submit
would also be refused although the caller had answered: a false refusal (§13). **No Phase 1 live call exercised the refusal
path.** (Update 2026-10-01: Phase 2's normal-assistant call, Vapi/DB #20, did: a premature submit refused live; Phase 2's two
fault-injection attempts did not produce one. See the verification log.)

## 9. What the live calls demonstrate

- The pipeline works end to end in a real browser call: signed console token, webhook authentication, tool contract, recorded tool
  calls, server-authoritative board, lifecycle and cost/duration reporting, Action Cable updates.
- The server state was correct for every tool call it received, including when the model's choices were wrong.
- The failure classes above are real and recurrent at this model/configuration (not hypothetical).
- The turn-evidence signal distinguishes a premature submit (0 caller turns) from a submit after the caller's answer (1 turn), live.
- Duplicate-submit protection works live (Call #6).
- With the gate and the aligned prompt in place, one call (Call #7) completed correctly with the gate passing.

## 10. What the live calls do NOT demonstrate

- Any rate: nine calls (one invalid), two scripted scenarios.
- The gate's refusal path in a live call (first seen in Phase 2, Vapi/DB call #20).
- The effect of `reasoningEffort: low` (Vapi sent `minimal` for the conversation regardless).
- The SMS path to a real phone (web calls have no number), web-call transfer, large-order and closed-hours rules live.
- How the model handles unclear replies in general (Call #9 is one attempt: it dropped the reply rather than clarifying).
- Production operation, load, or cost at scale.

## 11. Automated test and evaluation results (this run, local)

| Check | Result |
|---|---|
| Full suite `bin/rails test` | 406 runs, 3,524 assertions, 0 failures, 0 errors, 2 skips (retired R21/R22) — update run |
| Replay suite (`live_call_replay_test.rb`) | 6 runs, 0 failures |
| Reliability R-suite | 25 runs, 0 failures, 2 skips (R21/R22 retired); one earlier standalone run had 1 failure, not reproduced in 30 reruns (cause unknown) |
| Evaluation harness + evidence (`test/services/evaluation`) | 23 runs, 0 failures (update run); committed evidence matches a fresh run (15 scenarios; both safety invariants hold in 15/15); the evidence builders are now tested directly |
| JavaScript console modules (node) | pass |
| `bin/rails baseline:verify` | OK — frozen originals pass against `portfolio-baseline` (25 runs) |
| Line coverage (stdlib `Coverage`) | 93.5 % of `app/**/*.rb` (Phase 0: 65.7 %); every `app/services` file ≥ 95 % |
| CI | not run at the time of this table; later green on GitHub Actions (see "Remaining acceptance work" below) |

## 12. Security and reliability checks

RuboCop: 142 files, no offenses. Brakeman: 0 warnings. bundler-audit: no vulnerabilities. importmap audit: no vulnerable packages.
`vapi:check`: OK (tools, prompt, events, limits, webhook; secret matches). Webhook fails closed without a ≥16-character secret; the old
default is never accepted; no payload values are logged; production forces TLS; secrets scan and page/broadcast leak tests pass; tool
responses carry no exception text or SQL; the gate stores no transcript text.

## 13. Known limitations

- The agent's conversational reliability is not established: premature submits (2 of 4), announced-but-not-made tool calls, spoken
  reasoning, filler stacking, unscripted questions, a repeated greeting.
- The gate relies on the order of Vapi's history; Call #7 showed that history splitting one caller reply around the submit, and
  Call #2's history stamps the caller's answer 0.1 s after the submit although the model had it: against that payload the gate
  refuses a confirmed order (a false refusal; fails closed). Not fixed; a Phase 3 candidate.
  Timestamps in it are not precise speech timing.
- Reasoning effort is not a controllable variable through the assistant configuration; `vapi:check` validates configuration, not the
  downstream request.
- The console's claim heuristic is a heuristic (documented false positive and negative in the evaluation).
- Speech-to-text errors are outside the server's control.
- The `submit_order` tool description still says `confirmation_sms` "says whether" a text was queued (it is now absent when not queued).

## 14. Deferred work

- Not built by design (`PLAN.md` §15): second provider, payments, multi-restaurant, HMAC (Phase 4 optional), JWT, Vapi write
  automation, SMS status tracking, recording redirect, server-side live transcripts, LLM judge, web-call transfer, and the rest of §15.
- Not done yet: the rest of plan step 17 (`docs/voice_agent/tools.md`, `vapi_setup.md` and parts of `local_setup.md` still describe
  the removed `api/voice` layer; the README was rewritten in the update); Layer 3a/3b
  live-model sampling (plan §8, Phase 2); a real-phone SMS test; a live observation of the gate refusing; the unclear-upsell live
  attempt.

## 15. Is Phase 1 complete?

**Yes, as of 2026-10-01** (see the end of this report). The blockers as listed before then:

1. ~~**#9 / #17 — CI**~~ — resolved 2026-10-01 (green CI run, see the end of this report).
2. ~~**#20 — unclear-upsell live attempt**~~ — resolved 2026-10-01 (Call #9, recorded in the verification log).

(#18 was resolved in the update.) Also outstanding against the plan's step list (not a §14 criterion): the rest of **step 17**
(`tools.md`, `vapi_setup.md`, `local_setup.md`). Unexplained: one intermittent reliability-suite failure (§2, #17), not reproduced.

## Portfolio conclusion

The strongest result is architectural, not a claim about the model. The project separates four things and keeps them separate in
code and in the console:

- **conversational/model behaviour** (Vapi + `gpt-5-mini`): probabilistic, observed, never trusted as a fact;
- **authoritative commerce state** (Rails): cart, prices, versions, order status, changed only through `OrderTaking`;
- **deterministic server-side invariants**: read-back versioning, immutability after submit, idempotent tool calls, and a
  turn-taking gate derived from the provider's own conversation history;
- **observable evidence**: a recorded `ToolInvocation` for every server action, turn evidence at submit, replayable fixtures from
  real calls, and a console that shows the model's words next to the server's decisions.

Live testing showed the model submitting before the caller answered in 2 of 4 calls that reached submission (corrected from 3 of 4). The response was not a
stronger prompt but a server invariant, verified against the real recorded payloads. The model proposes. The server decides.

---

## Remaining acceptance work (2026-10-01)

### #9 / #17 — CI

The branch was pushed and draft PR https://github.com/amitkssolanki/ai-receptionist/pull/17 opened (the CI workflow runs on pull
requests and on pushes to `main`, not on other branch pushes). CI result:

- First run, [36759683861](https://github.com/amitkssolanki/ai-receptionist/actions/runs/36759683861) at `1e4d12f`: `lint`,
  `scan_js`, `scan_ruby` passed; `test` failed — 406 runs, 1 failure:
  `HermeticCredentialsTest#test_the_Rails_secret_key_base_is_still_available_(only_vapi.*_is_hidden)`. Cause: a Phase 1 test
  asserted `Rails.application.credentials.secret_key_base`, which needs `config/master.key`; CI has none, so the encrypted
  credentials cannot be read there. Not a product failure.
- Fix, commit `627863a` (test file only): the test checks `Rails.application.secret_key_base`, and the decrypted credentials only
  where a master key exists. The `vapi.*` hiding assertions are unchanged. Verified locally with and without a master key.
- Second run, **[36760252445](https://github.com/amitkssolanki/ai-receptionist/actions/runs/36760252445) at `627863a`: all four jobs green** — `test` (406 runs, 3519 assertions, 0 failures,
  0 errors, 2 skips), `lint`, `scan_ruby`, `scan_js`.

#9 and #17 are met. Not covered by CI: `baseline:verify` (not in the workflow; green locally).

### #20 — scripted unclear-upsell live attempt (manual procedure)

**Source of truth.** `PLAN.md` §14 #20: "the scripted unclear-upsell attempt is recorded"; §9: "Live demo: a scripted console run
recreating the unclear upsell reply". The only verbatim wording in the repository is Phase 0 call #7 (PLAN §9, `db_snapshot.json`):
the agent offered garlic knots/fries → caller "It should be." → agent asked to clarify → caller "That should be." → agent said
"Great. I'll add garlic knots…" without calling `add_to_cart`.

**Ambiguities in the plan (not resolved here — the owner decides):**
1. The plan does not give a full live script for this attempt. The procedure below reuses the current script for everything except
   the upsell answer, and uses the two Phase 0 replies verbatim for the upsell answer.
2. "It should be." / "That should be." are what speech-to-text heard in Phase 0, not necessarily what the caller said. Saying them
   verbatim recreates the transcript the model saw; it may not recreate the original audio.
3. The unclear reply is to the **upsell offer** (PLAN §9), not to the read-back.
4. The plan defines no pass/fail for the model's reaction; #20 requires the attempt to be **recorded**. Whatever the agent does is
   the result.

**Preflight:** `bin/dev` running (no migrations since the last restart); `ngrok http --url=salaried-earplugs-appendix.ngrok-free.dev 3000`
running; `VAPI_EXPECTED_HOST=salaried-earplugs-appendix.ngrok-free.dev bin/rails vapi:check` prints `OK`; Chrome at
`http://localhost:3000/admin/console`, signed in, `server link ● connected`; headphones on. Do not change the prompt, model or tools.

**Script** (wait for the agent to finish each turn; do not improvise other wording):

1. Click **● Start call**; wait for the greeting to finish.
2. "Hi, what pizzas do you have?"
3. "Tell me about the Margherita."
4. "I'll have one Margherita with extra cheese, for pickup."
5. When the agent offers an add-on (garlic knots and/or a drink or fries), say exactly: **"It should be."**
6. If the agent asks a clarifying question, say exactly: **"That should be."** If it does not ask, say nothing further about the
   add-on.
7. Let the agent continue. If it asks something unrelated (name, notes, pickup or delivery), answer briefly and truthfully
   ("Pickup", "Skip it").
8. "Can you read my order back?"
9. After the read-back: "Yes, that's right."
10. Let the agent finish, then click **■ End call**.

If the agent never offers an add-on at step 5, the scenario was not reached: end the call, record it as "upsell not offered", and
repeat with a fresh call rather than prompting for an add-on.

**Observe, without intervening:** after steps 5–6, whether the agent (a) asks a plain yes/no question, (b) adds the item with an
`add_to_cart` row on the server, (c) says it added something with no matching server row (the console marks `⚠ claim not
reflected in the server order (heuristic)`), or (d) does something else. Then whether the read-back matches the order board, and
what the confirmation gate did at submit.

**Evidence to record for #20** (send it back; it goes into `docs/voice_agent/verification_log.md` as the next call entry):
- `bin/rails calls:last` output, run right after the call (payload-free, safe to paste);
- a console screenshot showing the conversation around steps 5–6, the order board, and the server event rows (including any `⚠`
  marker and the submit row's ◌ lines);
- in your words: what you said at steps 5 and 6, and what the agent said in reply;
- the final order as the board shows it (items, total, cart version, status).

From that the entry records: the Vapi/DB call id, the upsell offer, the ambiguous replies and the agent's reaction, whether any
claim was not reflected in the server order, the final authoritative order, the read-back and the gate result — and, from Vapi's
stored record (read-only), whether an `add_to_cart` was actually requested after the ambiguous reply.

### Current status

**20 of 20 criteria met; Phase 1 is complete against `PLAN.md` §14.** #9 and #17 are met by the green CI run above, and #20 by
Call #9 below. Still outstanding outside §14: the rest of plan step 17 (`tools.md`, `vapi_setup.md`, `local_setup.md`), and the
unexplained one-off reliability-suite failure (§2, #17).

#20 attempts so far:
- **Attempt 1 — Call #8 (Vapi/DB call #15), 2026-10-01: upsell not offered (scenario not reached).** Speech-to-text heard the
  scripted "Hi, what pizzas do you have?" as "What business do you have?" four times; the model answered each time by repeating its
  greeting and called no tool. No cart, no order, no add-on offer, so the unclear reply was never said. Details in
  `docs/voice_agent/verification_log.md`.
- **Attempt 2 — Call #9 (Vapi/DB call #16), 2026-10-01: recorded; satisfies #20.**
  - The model offered garlic knots after the `add_to_cart` result: "Would you like garlic knots with that?"
  - The scripted reply was "It should be."; speech-to-text recorded "Should be—", and that is what the model received.
  - The model answered "One moment." and then nothing: no clarifying yes/no question (which the prompt asks for), no
    `add_to_cart`, and no claim of adding anything. "That should be." was not needed.
  - The caller moved on 21 s later. Read-back: 1 × Margherita Pizza with extra cheese, $16.00.
  - After "Yes, that's right." the gate passed (1 caller turn after the read-back). Order #10 CONFIRMED at v1, $16.00, no
    garlic knots. No `⚠ claim not reflected` marker in the console screenshot.
  - Outcome: safe (the server state is exactly what was ordered), but the unclear answer was dropped, not clarified.
  - `PLAN.md` defines no pass/fail for the model's reaction, so none is asserted here. Details: `docs/voice_agent/verification_log.md`.

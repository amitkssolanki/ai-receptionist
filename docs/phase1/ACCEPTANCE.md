# Phase 1 acceptance report

Status as of 2026-09-30, branch `phase-1-reliability-console` (not pushed); first written after commit `1f1fb5b`, updated after
commit `1918acb` (criterion #18 and the README). Source of truth for the
criteria: `docs/phase1/PLAN.md` §14. Evidence: this repository, `docs/phase1/EXECUTION_LOG.md`, `docs/phase1/evidence/`,
`docs/voice_agent/verification_log.md`, and the verification run recorded in §11 below.

**Verdict: Phase 1 is not complete by the letter of `PLAN.md` §14.** 17 of 20 criteria are met; 3 are incomplete or not
demonstrated (§2): CI has never run on the branch (#9, #17) and the scripted unclear-upsell live attempt has not been made (#20).
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
| 9 | Layer 2 replays green **in CI**; `baseline:verify` reproduces 23/23 + 2/2 | **Incomplete (CI)** | Replays green locally (6 runs); `baseline:verify` OK (25 runs). The branch has never been pushed, so no CI run exists for any Phase 1 commit |
| 10 | `get_menu` ≤ 3 queries (constant when doubled), ≤ 1,600 bytes; benchmark recorded | **Complete** | `menu_performance_test.rb`; `EXECUTION_LOG.md` benchmark (median of 50, before vs after); 51 → 3 queries, 4,554 → 1,526 bytes |
| 11 | Console starts/stops a real Vapi web call and shows live partial/final transcripts | **Complete** | Live calls #1–#7 from `/admin/console` (screenshots, verification log); partial→final handling in `test/javascript/transcript.test.mjs` |
| 12 | Server rows live; pending rows resolve to server rows by toolCallId; board = DB | **Complete** | `console_broadcaster_test.rb`; `claims.test.mjs` (DOM ids match the server's); `console_backfill_test.rb` "what the state frame rebuilds equals what the live stream delivered"; live Call #3 showed unresolved pending rows when the server had no record (as designed) |
| 13 | Console resyncs after a Cable reconnect and in review mode | **Complete** | `console_backfill_test.rb` (missed events present after reload; state frame from the DB alone) |
| 14 | Secrets scan passes | **Complete** | `test/security/secrets_scan_test.rb`; `console_broadcaster_test.rb` "nothing sensitive is broadcast…"; `console_controller_test.rb` "only the public key and assistant id reach the browser" |
| 15 | `vapi:check` passes; baseline assistant unchanged | **Complete** | `vapi:check` OK (§11); baseline `8f2053ae…` `updatedAt` 2026-08-06T02:49:50.807Z, identical to Phase 0 |
| 16 | Webhook rejects missing/wrong secrets; no default outside `test` | **Complete** | `webhook_security_test.rb` (8 tests, incl. "the known old default is never accepted") |
| 17 | Tests, RuboCop, Brakeman, bundler-audit, importmap audit green; **CI green** | **Incomplete (CI)** | All local checks green (§11). CI not demonstrated: branch never pushed. One standalone run of the reliability suite had 1 failure that did not recur in 30 further standalone runs or in the full suites; the failing test was not captured and the cause is unknown |
| 18 | Coverage ≥ 65.7 % baseline; new service files ≥ 95 % | **Complete** (update) | The criterion has no exclusion for tooling, so all new `app/services` files count. Added tests of real behaviour (commit `161485a`): `evaluation.rb` 85.7 → 100 %, `evaluation/evidence.rb` 19.8 → 100 %, `vapi_config/client.rb` 80.0 → 100 %. Every `app/services` file is now ≥ 95 % (lowest `voice/turn_evidence.rb` 96.5 %); overall 93.5 % of `app/**/*.rb` (Phase 0: 65.7 %). Measured with stdlib `Coverage`, single process |
| 19 | Verification log records the outcome of every Phase 0 UNKNOWN touched | **Complete** (see note) | Recorded: metadata arrival (yes), webhook secret over ngrok (works), tool contract accepted, end-of-call fields (arrive, ~57 s late once), live assistant state, `PATCH` of `model` preserves other top-level fields, public-key restrictions/spend limit not API-readable. Note: tool-call-ID reuse on redelivery was **not observed** (no redelivery in 7 live calls; 0 duplicates absorbed from redelivery) — first recorded here. Not touched (deferred/out of scope): HMAC, JWT algorithm, web-call transfer, recording retention, `silenceTimeoutSeconds` |
| 20 | A live call shows a tool-backed order end to end, **and** the scripted unclear-upsell attempt is recorded | **Incomplete** | First half met (Calls #2, #6, #7). The unclear-upsell attempt (the garlic-knots "That should be" case) was never scripted live; the live script used a clear "Yes, add the garlic knots." |

## 3. What live testing discovered

Seven live browser calls (owner's numbering; Vapi/DB ids in brackets). Details: `docs/voice_agent/verification_log.md`.

| Call | Runtime reasoning | Outcome |
|---|---|---|
| #1 (#8) | `minimal` | Added on a question; duplicate Margherita line; **submit 2.1 s after `get_cart`, 0 caller turns**; wrong order $35.50 (server correct for what it was told) |
| #2 (#9) | `minimal` | Correct $21.50; **read-back and submit in one model completion, 0 caller turns** (the 12.9 s gap was the agent's speech); spoken reasoning; SMS fact volunteered |
| #3 (#10) | — | **Invalid run**: stale `bin/dev` after a migration + fallback locking bug; no conclusions |
| #4 (#11) | `minimal` | Announced "Getting your cart" with **no tool call**; went silent; abandoned; "Added…" spoken before the tool result |
| #5 (#12) | configured `low`, runtime `minimal` | Garbled first utterance; "One moment." with no tool call; stalled |
| #6 (#13) | configured `low`, runtime `minimal` | **Premature submit, 0 caller turns**, 1.2 s after the read-back fetch; second submit after the caller's yes absorbed; promised a text that was not sent |
| #7 (#14) | `minimal` (+2 Azure requests at `low`, purpose unknown) | Correct $21.50; **1 caller turn** before the submit; model input ended with the caller's "Yes. That's right."; gate passed; no SMS promise |

## 4–6. Failure modes and how each was addressed

| Failure mode | Seen in | Response | Kind of fix |
|---|---|---|---|
| Premature submit (before the caller answered) | Calls #1, #2, #6 (3 of 4 that reached submit) | Confirmation gate (§8) | **Server invariant** (deterministic) |
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

It was added because of the live evidence (3/3 premature submits) and is an architectural safeguard. **Call #7's compliant behaviour
does not make it unnecessary.** Against the real recorded submits it behaves as intended: the premature submits of Calls #1, #2 and #6
would each be refused; Call #6's later submit after the caller's yes would be accepted
(`test/controllers/api/vapi/confirmation_gate_test.rb`, `live_submit_webhook_*.json`). **No live call has yet exercised the refusal
path.**

## 9. What the live calls demonstrate

- The pipeline works end to end in a real browser call: signed console token, webhook authentication, tool contract, recorded tool
  calls, server-authoritative board, lifecycle and cost/duration reporting, Action Cable updates.
- The server state was correct for every tool call it received, including when the model's choices were wrong.
- The failure classes above are real and recurrent at this model/configuration (not hypothetical).
- The turn-evidence signal distinguishes a premature submit (0 caller turns) from a submit after the caller's answer (1 turn), live.
- Duplicate-submit protection works live (Call #6).
- With the gate and the aligned prompt in place, one call (Call #7) completed correctly with the gate passing.

## 10. What the live calls do NOT demonstrate

- Any rate: seven calls (one invalid), one scripted scenario.
- The gate's refusal path in a live call.
- The effect of `reasoningEffort: low` (Vapi sent `minimal` for the conversation regardless).
- The SMS path to a real phone (web calls have no number), web-call transfer, large-order and closed-hours rules live.
- The unclear-upsell ("That should be") case live.
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
| CI | **not run** (branch not pushed) |

## 12. Security and reliability checks

RuboCop: 142 files, no offenses. Brakeman: 0 warnings. bundler-audit: no vulnerabilities. importmap audit: no vulnerable packages.
`vapi:check`: OK (tools, prompt, events, limits, webhook; secret matches). Webhook fails closed without a ≥16-character secret; the old
default is never accepted; no payload values are logged; production forces TLS; secrets scan and page/broadcast leak tests pass; tool
responses carry no exception text or SQL; the gate stores no transcript text.

## 13. Known limitations

- The agent's conversational reliability is not established: premature submits (3/4), announced-but-not-made tool calls, spoken
  reasoning, filler stacking, unscripted questions, a repeated greeting.
- The gate relies on the order of Vapi's history; Call #7 showed that history splitting one caller reply around the submit.
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

**No, not by `PLAN.md` §14.** Remaining blockers, exactly:

1. **#9 / #17 — CI:** push the branch (or otherwise run CI) and get a green run of the test, lint and security jobs.
2. **#20 — unclear-upsell live attempt:** one scripted live call reproducing the unclear upsell reply, recorded in the verification
   log.

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

Live testing showed the model submitting before the caller answered in 3 of 4 calls that reached submission. The response was not a
stronger prompt but a server invariant, verified against the real recorded payloads. The model proposes. The server decides.

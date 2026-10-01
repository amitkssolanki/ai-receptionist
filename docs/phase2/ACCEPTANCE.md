# Phase 2 acceptance report: the thesis on camera

Status as of 2026-10-01, branch `phase-2-thesis-on-camera` (from `phase-1-reliability-console` at `c28ca09`; not pushed, not
merged). Plan: Option B of the Phase 2 assessment, approved with 8 fixed criteria (P2-1 to P2-8). Evidence: this repository,
[`docs/voice_agent/verification_log.md`](../voice_agent/verification_log.md) (Phase 2 entries from 2026-10-01) and
[`docs/CASE_STUDY.md`](../CASE_STUDY.md).

**Verdict: 6 of 8 criteria met; P2-3 attempted, not demonstrated; P2-7 pending the owner's video.** Phase 2 closes when the owner
confirms the video exists, or at the calendar limit with P2-7 recorded as "script ready, not recorded".

## Criteria

| ID | Criterion | Status | Evidence |
|---|---|---|---|
| P2-1 | A separate, clearly labelled fault-injection assistant built from committed files; only the name, first message and an appended prompt differ | **Met** | `config/vapi/fault_injection_prompt.md`, `fault_injection.json`, `fault_injection.md`; `VapiConfig.profile`; assistant `5e1f3eec…` created with one `POST /assistant` (owner's instruction), compared field by field with the dev assistant (only the prompt differs besides name/first message/ids); `vapi:check PROFILE=fault_injection` OK; `test/services/vapi_config/fault_injection_profile_test.rb`, `test/lib/vapi_rake_test.rb` |
| P2-2 | Same server authority: no server path depends on the assistant | **Met** | `test/controllers/api/vapi/assistant_identity_test.rb`: Call #1's recorded premature submit sent as either assistant gets the identical refusal, record and order state; `call_logs.assistant_id` is evidence only. `OrderTaking`, `ToolRunner`, `TurnEvidence`, webhook authentication and tools unchanged |
| P2-3 | A live call shows the fault-injection assistant attempting a premature submit and Rails refusing it | **Attempted, not demonstrated** | 2 of 5 fault calls used; attempts 3–5 not made (owner decision). Attempt 1 (DB #17) stalled before the order. Attempt 2 (DB #18) reached the read-back; every request carried the appendix; the model waited for the caller (its decision ran on Vapi's Azure fallback at `low` after an OpenAI provider fault). The prompt was not changed and no other mechanism was added. See "Unplanned: the first live refusal" below |
| P2-4 | The refusal and its evidence are understandable within seconds; fault-injection calls are labelled | **Met** (in two calls) | Label: red banner on `/admin/console?assistant=fault_injection`, "FAULT INJECTION · test assistant" on the server-call panel and in `calls:last` (DB #17, #18; `test/controllers/admin/console_fault_injection_test.rb`). Refusal: shown live in DB #20 (normal assistant): ⛔ `customer_confirmation_required`, "0 caller turns since the last get_cart; nothing was submitted, v1 kept", the gate line, the board's "submit refused … (v1)" (screenshot, screen recording). The claim marker was not exercised (the injected claim was never spoken) |
| P2-5 | After the fault-injection calls, the unchanged normal assistant completes a confirmed order | **Met, with a caveat** | DB #20: order #12, 1 × Margherita Pizza with Extra cheese, $16.00, CONFIRMED at v1 after the caller's "yes"; gate passed on that submit. **Caveat:** the caller never asked for that item or option; the model added it after "Tell me about the margarita." and chose extra cheese itself; the caller confirmed the read-back while following the test script. Dev assistant `updatedAt` 2026-09-30T17:55:36.802Z and all fingerprints identical before and after Phase 2; `vapi:check` OK. 2 of 3 normal calls used (DB #19 ended early: recording problem) |
| P2-6 | A concise case study, linked from the README, every claim linked to evidence | **Met** | `docs/CASE_STUDY.md`; `test/docs/case_study_links_test.rb` (every relative link resolves; the README links it) |
| P2-7 | Demo script and recording plan; a 2–3 minute video confirmed by the owner | **Pending** | `docs/phase2/DEMO_SCRIPT.md` (storyboard, voiceover, shot list, caller lines, checklist); `docs/phase2/gate_test.tape` (VHS, rendered and checked); raw footage of DB #20 recorded (OBS, 1920×1080). The edited video is not confirmed yet |
| P2-8 | Fix only the contradictions the case study and Phase 2 evidence depend on | **Met** | Phase 1 report and README: nine calls, the premature-submit count (2 of 4), Call #7's Azure requests, CI, the live-refusal statements, the browser public key; test names/comments and one scenario text for Call #2 (evidence regenerated: text and timings only). `tools.md`, `vapi_setup.md`, `local_setup.md` untouched |

## Unplanned: the first live refusal (DB #20, normal assistant)

During the P2-5 call the unchanged normal assistant, on its configured path (OpenAI `gpt-5-mini`, `minimal`, no fallback), read the
order back and submitted in the same response with no caller turn. Rails refused it (`customer_confirmation_required`); the order
stayed open at v1; the model asked again; after the caller's "yes" the submit was accepted. Verified from Vapi's per-call model log.
This is the thesis observed live, unprompted. It does not change P2-3, which concerns the fault-injection assistant.

## Findings recorded during Phase 2

- **Correction of Phase 1's count:** by the model's actual input, 2 of 4 Phase 1 calls that reached checkout submitted early
  (Calls #1, #6), not 3 of 4; Call #2 was not premature.
- **False refusal (known limitation, not fixed):** the gate reads the order of Vapi's history, which stamped Call #2's "yes" 0.1 s
  after the submit; against that recorded payload the gate refuses a confirmed order. Fails closed.
- **Provider fallback:** when OpenAI does not respond, Vapi retries on Azure OpenAI with `reasoning_effort: "low"` (DB #14, DB #18).
- **Model behaviour, recorded not fixed:** "One moment." stalls (DB #17, #18); an unrequested `add_to_cart` after "Tell me about the
  margarita.", with an option (extra cheese) the caller never chose (DB #20), against two explicit prompt rules; misheard speech
  (DB #19). The server cannot tell an order from a question: it accepts any valid add to the open cart. The protection is downstream:
  the server-generated read-back states exactly what is in the cart, and nothing is submitted without a caller turn after it.
- **Console:** a call ended by Vapi shows "The call failed: [object Object]" instead of the reason (DB #17).
- **Browser public key** is unrestricted in the Vapi dashboard (owner-reported); `config/vapi/assistant.md` describes the intended
  restrictions.
- **CI tooling:** `bin/brakeman` runs with `--ensure-latest`; since Brakeman 8.1.0 was released it exits before scanning, so CI's
  `scan_ruby` job will fail until the gem is updated. The scan itself (Brakeman 8.0.6, run directly) is clean.

## Checks at the end of Phase 2 (local)

| Check | Result |
|---|---|
| Full suite `bin/rails test` | 431 runs, 3,682 assertions, 0 failures, 0 errors, 2 skips (retired R21/R22) |
| RuboCop | 148 files, no offenses |
| Brakeman (8.0.6, without `--ensure-latest`) | 0 errors, 0 security warnings |
| bundler-audit / importmap audit | no vulnerabilities / no vulnerable packages |
| `bin/rails baseline:verify` | OK |
| `vapi:check` / `vapi:check PROFILE=fault_injection` | OK / OK |
| Dev assistant vs the Phase 2 reference record | identical (`updatedAt`, settings, fingerprints) |
| CI | not run (the branch is not pushed) |

## Budget

| Item | Limit | Used |
|---|---|---|
| Fault-injection live calls | 5 | 2 |
| Normal live calls | 3 | 2 |
| External spend (Vapi) | $10 | $0.48 (DB #17–#20) |
| Calendar | 2 weeks | 1 day so far |

## Phase 3 candidates (not in scope)

The false-refusal / history-ordering limitation; measured model behaviour (Phase 2 assessment Option A); detecting failures the
server cannot see (Option C), including stalls and announced-but-not-made tool calls; the unrequested add; showing the model's text
instead of Vapi's transcription of the agent ("Tide"); the console's "[object Object]" end reason; provider-fallback control; the
browser public key's restrictions; the Brakeman version bump for CI; the stale `tools.md`, `vapi_setup.md`, `local_setup.md`; the
one-off reliability-suite failure.

# Case study: the model proposes, the server decides

A voice ordering agent for one restaurant, built to answer one question honestly: **when a language model drives a
transaction, what keeps the transaction correct when the model is wrong?** The answer here is architectural: the model's tool
calls are requests, and a Rails server owns every business fact. This page links each claim to the evidence in this repository.

## 1. The problem

Callers talk to a Vapi voice agent (`gpt-5-mini`); the agent orders by calling tools. Before this work the agent's account of
the order and the actual order could disagree. In the Phase 0 baseline the agent said "I'll add garlic knots" without calling
`add_to_cart`, read back a $16 order, and submitted it ([plan §9](phase1/PLAN.md), frozen evidence in
[test/fixtures/files/baseline](../test/fixtures/files/baseline)).

## 2. What live testing found

Nine live browser calls in Phase 1 (one invalid: a stale server after a migration), recorded with the server's records and,
where they were captured, Vapi's stored logs
([verification log](voice_agent/verification_log.md)). Among them:

- **Premature submits.** In **2 of the 4 calls that reached checkout** (Calls #1 and #6) the model submitted the order before the
  caller had answered the read-back. Vapi's per-call model logs show the request that produced `submit_order` ended with the
  `get_cart` result, not with anything the caller said ([verification log](voice_agent/verification_log.md), entry "Forensic
  analysis of fault-injection attempt 2; correction of the premature-submit count"). Phase 1 first counted 3 of 4; Call #2 was
  later found not to be premature (see §5). In Phase 2 the normal assistant did it again on a live call (Vapi/DB call #20), and
  the gate refused it (§5).
- **Announced actions that never happened** ("Getting your cart" with no tool call), stalls after a filler ("One moment." and then
  nothing), adding an item the caller had only asked about (Call #1; again in Vapi/DB call #20, where it also chose an option the
  caller never mentioned), spoken reasoning, misheard
  speech ([Phase 1 report §3–§6](phase1/ACCEPTANCE.md), [verification log](voice_agent/verification_log.md)).
- In every valid call, **the server's state was correct for what it was asked**: Call #1's wrong order ($35.50) was exactly what the
  model requested, and the console showed it ([Phase 1 report §7](phase1/ACCEPTANCE.md)).

## 3. Architecture

```
browser console ──WebRTC── Vapi (speech-to-text → gpt-5-mini → text-to-speech)
                                  │ tool calls (authenticated webhook)
                                  ▼
                Rails: Voice::ToolRunner → OrderTaking / MenuCatalog → Postgres
                                  │ after commit
                console order board + server event stream (Action Cable)
```

One authenticated webhook ([webhooks_controller.rb](../app/controllers/api/vapi/webhooks_controller.rb)) hands every tool call to
[Voice::ToolRunner](../app/services/voice/tool_runner.rb): idempotent by tool-call id, arguments validated, the result and the cart
versions recorded as a `ToolInvocation` in the same transaction. [OrderTaking](../app/services/order_taking.rb) applies the rules
under row locks. The console shows the model's words ("source: VAPI · not authoritative") next to the server's records ("source:
RAILS · authoritative").

## 4. Why Rails is authoritative

- **Prices and totals come from the menu**, never from tool arguments (R19 in
  [reliability_characterization_test.rb](../test/baseline/reliability_characterization_test.rb)).
- **The cart is versioned and the read-back is server-generated**: `get_cart` returns `readback_text` and records which version was
  read; `submit_order` must quote that version ([order_taking/readback.rb](../app/services/order_taking/readback.rb)).
- **Submitted orders are immutable; duplicate deliveries are absorbed** (one execution per tool-call id; evidence in
  [idempotency_and_versions.json](phase1/evidence/idempotency_and_versions.json)).
- **Claims are not facts.** Across 15 scripted conversations run through the real server path, 6 of the assistant's 11 order
  claims were not reflected in the server order, and two invariants held in all 15: every order line came from an accepted
  `add_to_cart`, and an order is confirmed only at the read-back version
  ([garlic_knots_probe.json](phase1/evidence/garlic_knots_probe.json), [evidence README](phase1/evidence/README.md)).

## 5. The confirmation gate

Because of the premature submits, `submit_order` is refused with `customer_confirmation_required` unless Vapi's conversation
history, in the same webhook, shows **at least one caller turn after the last `get_cart` result**. Missing or unreadable history
fails closed. It is a turn-taking check, not a judgement of what the caller said
([turn_evidence.rb](../app/services/voice/turn_evidence.rb), [order_taking.rb](../app/services/order_taking.rb)).

- **Against the real model's mistakes:** the recorded `submit_order` webhooks of Calls #1 and #6
  ([live_submit_webhook_call8.json](../test/fixtures/files/vapi/live_submit_webhook_call8.json),
  [live_submit_webhook_call13_first.json](../test/fixtures/files/vapi/live_submit_webhook_call13_first.json)) are refused, and
  Call #6's later submit after the caller's "yes" is accepted
  ([confirmation_gate_test.rb](../test/controllers/api/vapi/confirmation_gate_test.rb)). Call #6 happened before the gate was
  enforced: its review page shows the submit with 0 caller turns, issued by the same model response that answered the
  `get_cart` result.
- **Live, with the gate on:** Calls #7 and #9 submitted after the caller's answer and the gate passed. Then, in Phase 2, the
  unchanged normal assistant read the order back and submitted in the same response with no caller turn (Vapi/DB call #20, on its
  configured path: OpenAI, `minimal`, no fallback). Rails refused it with `customer_confirmation_required`; the order stayed open
  at v1; the model asked "Did I get that right?" again, and after the caller's "yes" the submit was accepted. It is the only live
  refusal so far ([verification log](voice_agent/verification_log.md), entry "Phase 2 normal-assistant call 2 of 3").
- **A false refusal, found later:** in Call #2 the model had the caller's "Yes. That's right." before it submitted, but Vapi's
  history stamps that turn 0.1 s after the submit, so the gate refuses that recorded payload. It fails closed (no wrong order;
  the caller confirms again). Recorded as a known limitation, not fixed.

## 6. Fault injection: an honest negative result

To show the gate refusing live, Phase 2 added a separate, labelled **fault-injection assistant**: the normal assistant plus a
committed appendix telling it to submit straight after `get_cart` and to claim "a free garlic knots"
([fault_injection_prompt.md](../config/vapi/fault_injection_prompt.md), [checklist](../config/vapi/fault_injection.md)). It uses
the same webhook, tools and rules; a test sends Call #1's premature submit from both assistants and gets the identical refusal
([assistant_identity_test.rb](../test/controllers/api/vapi/assistant_identity_test.rb)). The console labels its calls
([console_fault_injection_test.rb](../test/controllers/admin/console_fault_injection_test.rb)).

**It did not produce the failure.** Attempt 1 stalled before an order existed. Attempt 2 reached the read-back with the appendix in
every model request, and the model asked "Did I get that right?" and submitted only after the caller's yes; it never made the
injected claim either. That decision ran on Vapi's Azure fallback at `low` reasoning effort after an OpenAI provider fault. The
live refusal was **attempted, not demonstrated** (2 of the 5 allowed calls used), and the prompt was not tuned to force it
([verification log](voice_agent/verification_log.md), Phase 2 entries).

Minutes later, the normal assistant, told to wait, submitted early on its own (Vapi/DB call #20, §5). The lesson is the one the
gate encodes: a prompt makes a model's behaviour more or less likely, in either direction, but not certain. The normal prompt did
not stop Calls #1 and #6, or call #20, submitting early; an explicit instruction did not make attempt 2 do it. What is certain is
what the server accepts.

## 7. Evidence and checks

- The full test suite, the reliability rules R01–R24, replays of real calls, and the evaluation harness with committed,
  self-checking evidence ([README: Tests](../README.md#tests-evaluation-and-checks), [evidence](phase1/evidence/README.md)).
- Phase 1 closed at 20 of 20 acceptance criteria with green CI ([Phase 1 report](phase1/ACCEPTANCE.md)).
- Phase 2 (this demonstration layer): 6 of 8 criteria met, the fault-injection live refusal attempted but not demonstrated, the
  video pending ([Phase 2 report](phase2/ACCEPTANCE.md)).
- `bin/rails vapi:check` (and `PROFILE=fault_injection`) compares the live assistants with the repository, read-only
  ([vapi.rake](../lib/tasks/vapi.rake)).

## 8. Known limitations

- The agent's conversational reliability is not established (stalls, fillers, announced actions, misheard speech, unrequested
  adds). The server keeps the order exactly what was read back and answered; it cannot tell whether an add was what the caller
  meant (call #20: an item the caller only asked about became an order because the caller confirmed the read-back).
- The gate depends on the ordering of Vapi's history (the Call #2 false refusal above).
- One live refusal so far (Vapi/DB call #20); otherwise the refusal is shown against recorded real payloads. No rates: a handful
  of calls.
- Reasoning effort is not controllable through the Vapi assistant: provider fallbacks change it per request.
- The browser public key is not restricted in the Vapi dashboard.
- Not built: payments, phone calls and SMS delivery, call transfer, multiple restaurants, deployment
  ([README: Known limitations](../README.md#known-limitations)).

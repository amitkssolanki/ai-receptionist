# Next-phase handoff

The clean starting document for any future work on the AI Restaurant Receptionist. Written 2026-10-08 at the repository
closeout. Facts and numbers are in [`CURRENT_STATE.md`](CURRENT_STATE.md); this page says what to rely on and what to keep.

## Starting point

- Branch from **`main`** (the only branch). The code baseline is `fab8b2e`; the closeout added documentation-only commits on top
  of it, so start from the current `origin/main` (`git log -1 origin/main`).
- The working tree of a fresh clone is clean. On the owner's machine the encrypted credentials file shows as modified: that is
  local configuration, never committed.
- CI (`scan_ruby`, `scan_js`, `test`, `lint`) is green on `main`; `bin/rails baseline:verify` passes.
- Production runs `f964ef7`. `main` is ahead of production by two dependency updates (Rails 8.1.4, solid_cable 4.1.0) and
  documentation; deploy them, or not, as a deliberate step with the runbook's checks.

## What is complete

- **Core Rails application:** menu, cart, orders, call logs, admin; prices and totals from the menu; versioned carts.
- **Server-authoritative tool execution:** one authenticated webhook; `Voice::ToolRunner` validates arguments, executes each
  tool call once (idempotent by tool-call id) and records a `ToolInvocation` in the same transaction as the business change.
- **Reliability architecture:** server-generated read-back at a recorded cart version; submit only at that version; submitted
  orders immutable; the confirmation gate; reliability rules R01–R24, replays of real calls, the evaluation harness with
  self-checking evidence.
- **Dashboard and console:** `/admin` dashboard; `/admin/console` with the live conversation (marked not authoritative), the
  order board and the server event stream; per-call review pages.
- **Vapi browser voice:** development and production assistants configured from committed files (`config/vapi/`),
  `vapi:check` for read-only drift detection.
- **Production deployment:** Kamal, TLS, a dedicated database, runbook with checks and rollback.
- **Security and authentication:** admin-only app behind Devise (no sign-up, no reset), webhook secret with no default,
  restricted production key, TLS, parameter filtering, secret-scan test, Brakeman/bundler-audit/importmap audit in CI.
- **Portfolio and publication:** public GitHub repository; case study ([`CASE_STUDY.md`](CASE_STUDY.md), and published on the
  owner's site); an approved portfolio video (owner-held; the local renders are git-ignored).

## Architectural invariants

Preserve these in any future phase unless a phase explicitly and deliberately decides otherwise:

1. **Rails/the server is authoritative** for every business fact: cart, prices, totals, versions, read-back, order status.
2. **The Vapi transcript is not authoritative.** It is shown for context and labelled as such; nothing is derived from it as fact.
3. **Model output cannot directly establish authoritative order state.** Tool calls are requests; only server rules change state.
4. **Tool execution is validated server-side:** arguments, ids, quantities, modifiers, hours, versions, idempotency.
5. **Confirmation is enforced server-side:** `submit_order` needs a caller turn after the last read-back
   (`customer_confirmation_required` otherwise), failing closed on missing history.
6. **Browser voice is the current production mode.**
7. **Twilio/SMS are intentionally disabled** in production (no `TWILIO_*`; the SMS job no-ops).

## Production facts

- Hostname: `restaurant-receptionist.railsfanatics.com`.
- A production Vapi assistant exists, separate from the development, baseline and fault-injection assistants; the
  fault-injection assistant is development-only and refused by the production console.
- A dedicated production database (its own Postgres accessory) on shared VPS infrastructure with the owner's other apps and one
  shared `kamal-proxy`.
- The production public key is restricted to the production origin and the production assistant.
- `ADMIN_PASSWORD` was a one-time bootstrap variable and was removed after the first successful deployment.
- No secrets belong in Git. Secret names and where they live are in [`deploy/PRODUCTION.md`](deploy/PRODUCTION.md); values are
  in `.env.kamal` (git-ignored), the owner's password manager and the Vapi dashboard.

## Evidence

- **Production smoke call (2026-10-01):** the model issued a premature `submit_order`; Rails rejected it with
  `customer_confirmation_required`; the caller then confirmed; Rails accepted the second submit; the authoritative order
  (production order #1) became CONFIRMED. ([verification log](voice_agent/verification_log.md), "Production smoke call")
- **Development, Phase 2 (Vapi/DB call #20):** the same refusal live on the normal development assistant.
- Recorded real payloads, replays and the evaluation harness: [`phase1/evidence/`](phase1/evidence/README.md) and the test suite.
- An approved portfolio video exists; a public case study exists; the GitHub repository is public.

## Intentional exclusions

Not bugs and not unfinished work:

- no phone calling; no Twilio/SMS; no payments; no multi-restaurant support;
- no long-term production, load or uptime claim, and not "production-proven" in the sense of operational history;
- fault injection was attempted but not reliably reproduced live (P2-3 "attempted, not demonstrated");
- no customers; not a real restaurant.

## Next phase

**Not defined.** The repository was intentionally reset to a clean baseline: one branch, no open PRs, green CI, current
documentation. The next phase must define its own scope, criteria and budget before any implementation begins. Lists of
candidates in older documents (for example "Phase 3 candidates" in [`phase2/ACCEPTANCE.md`](phase2/ACCEPTANCE.md)) are inputs
to that decision, not a plan.

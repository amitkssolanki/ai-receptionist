# AI Restaurant Receptionist

A voice ordering agent for a single restaurant (the seed data's "Taj Zayka", open 24/7): a caller asks about the menu, orders
items with modifiers (pickup or delivery), hears the order read back, and confirms it. Built as a single-restaurant pilot.

The design rule is **"the model proposes, the server decides."** The voice pipeline and the language model run on
[Vapi](https://vapi.ai); every business fact — cart, prices, totals, cart version, read-back, order status, SMS — lives in this
Rails app and changes only through server-side rules. The model's tool calls are requests, not facts.

**Status:** Phase 1 (reliability + live voice console) is implemented and was verified with nine live browser calls. It is not
production software and the agent's conversational behaviour is not reliable (see [Known limitations](#known-limitations)).
Acceptance against the plan: [docs/phase1/ACCEPTANCE.md](docs/phase1/ACCEPTANCE.md).

**Case study:** [docs/CASE_STUDY.md](docs/CASE_STUDY.md): the failures this was built against, why the server is authoritative,
the confirmation gate, the fault-injection attempt, and the evidence for each claim.

## Architecture

```
Browser voice console (/admin/console, Devise)            Vapi (web call)
  mic / speaker ─────── WebRTC audio ───────────────────▶  speech-to-text → gpt-5-mini → text-to-speech
  conversation panel ◀── Vapi client messages ──────────   │
                                                            │ tool-calls / status-update / end-of-call-report
  order board + server events ◀── Action Cable ──┐          ▼
                                                  │   POST /api/vapi/webhooks  (X-Vapi-Secret)
                                                  │     Api::Vapi::WebhooksController   envelope only
                                                  │       ├─ CallLifecycle            call start / transfer note / end
                                                  │       └─ Voice::ToolRunner         arguments, idempotency, audit, errors
                                                  │             ├─ OrderTaking         cart, read-back, submit (row locks)
                                                  │             └─ MenuCatalog         menu overview / item detail
                                                  └── ConsoleBroadcaster ◀── after commit
                                                        Postgres: orders, order_items, tool_invocations, call_logs, …
```

| Information | Source of truth |
|---|---|
| Speech, transcripts, what the agent said | Vapi (shown in the console as *not authoritative*) |
| Tool executions: arguments, result, status, error code, cart versions, timing | Rails `ToolInvocation` |
| Cart lines, modifiers, prices, totals, `cart_version`, read-back state, order status | Rails `Order` / `OrderItem` |
| Call lifecycle, ended reason, duration, cost | Rails `CallLog` (fed by Vapi server events) |

### Tool execution path

Vapi posts every event to one URL, `POST /api/vapi/webhooks`, authenticated by the `X-Vapi-Secret` header (there is no default
secret; requests are refused if none is configured). For each tool call the controller hands the tool name, arguments and the
webhook's conversation history to `Voice::ToolRunner`, which:

1. locks the call row and returns the stored result if this `toolCallId` was already executed (idempotent redelivery);
2. validates the arguments (`Voice::ToolArguments`); bad input becomes `invalid_arguments`, never an exception;
3. dispatches to `OrderTaking` / `MenuCatalog` / `CallLifecycle`, which apply the business rules;
4. records a `ToolInvocation` (arguments, the exact result the model was told, status, error code, cart versions, duration) in the
   same transaction as the business change;
5. returns a JSON string: the payload on success, `{"ok":false,"error":{"code":…,"message":…}}` on refusal. No exception text,
   SQL or class names ever reach the model.

The model has eight tools (`config/vapi/tools.json`): `get_menu`, `get_menu_item`, `add_to_cart`, `update_cart_item_quantity`,
`remove_cart_item`, `get_cart`, `submit_order`, `transfer_to_human`.

### Server-side rules

- Prices and totals come from the menu, never from tool arguments.
- The cart has a version (`cart_version`) that every change increments. `get_cart` returns a server-generated `readback_text`
  and records the read-back version; `submit_order` must quote the current version, and the read-back must be at that version.
- Submitted orders cannot be changed by the voice tools; an admin cannot reopen them. A repeated submit answers
  `already_submitted` and changes nothing.
- Quantity limits, large orders (hand off to staff), closed hours and invalid modifiers are refused with speakable error codes.
- **Confirmation gate.** `submit_order` is refused with `customer_confirmation_required` unless Vapi's conversation history in the
  same webhook shows **at least one caller turn after the last `get_cart` result, before the submit**. Missing or unreadable history
  fails closed. It is a turn-taking check, not a judgement of what the caller said; the evidence (counts and flags, never text) is
  stored with the submit. It exists because live calls showed the model submitting in the same breath as the read-back.
- **SMS.** A confirmation text is queued only for a caller with a real phone number (`OrderConfirmationSmsJob`, Twilio). The
  `submit_order` result mentions `confirmation_sms: "queued"` only when a text was queued; browser (web) calls have no number, so
  no text is sent and the model is told nothing about SMS.
- **`transfer_to_human`** records the request and the reason and marks the call transferred. It does **not** transfer the call:
  no transfer destination is configured, and browser web calls cannot be transferred to a phone.

### Voice test console and admin

- **Console** (`/admin/console`): start/stop a real Vapi web call from the browser microphone. Three areas: the live conversation
  (Vapi, partial and final transcripts), the **order board** rendered from the database (lines, total, cart version, read-back,
  confirmation, SMS), and the **server event stream** (every `ToolInvocation` with arguments, result, status, cart change, timing,
  turn evidence and what the confirmation gate did). Updates arrive over Action Cable after each commit; after a reconnect the page
  rebuilds from the database. `/admin/console/calls/:id` reviews a past or in-progress call. A heuristic marks agent lines that claim
  a cart change the server never made. Only the Vapi public key and the assistant id reach the browser (never the private key
  or the webhook secret).
- **Admin**: menu (categories, items, modifiers, upsell pairings), orders (status transitions, no reopening), call logs, settings
  (hours, timezone).

### Data model

`Restaurant` → `MenuCategory` → `MenuItem` → `MenuItemModifier`, `MenuItemUpsell` · `Customer` (by phone number) · `Order`
(`pending` → `confirmed` → …, plus `abandoned`; `cart_version`, `read_back_version`) → `OrderItem` (price and modifier snapshot) ·
`CallLog` (one per call; ended reason, duration, cost, transfer) · `ToolInvocation` (one per executed tool call; `turn_evidence`
on submits) · `User` (Devise, one restaurant).

## Setup

Prerequisites: Ruby 3.4.7 (`.ruby-version`; `.rvmrc` selects the `ruby-3.4.7@ai-receptionist` gemset) and PostgreSQL.

```
bundle install
bin/rails db:create db:migrate db:seed
bin/dev
```

`bin/dev` runs Rails and the Tailwind watcher on `http://localhost:3000`. The seed creates the restaurant, its menu and a local-only
admin login (`admin@example.com` / `password123`, development and test only). **After any migration, restart `bin/dev`**: a server
started before a migration cannot record tool calls.

Outside development and test the seed never creates that login: it creates an admin only from `ADMIN_EMAIL` and `ADMIN_PASSWORD`
(at least 16 characters), and without them no one can sign in. That is a one-time bootstrap of an empty database: once any user
exists, later seeds ignore both variables and never create, recreate or change an account. There is no sign-up and no emailed password reset; change a
password with `bin/rails runner`. Every page except sign-in and `/up` requires a signed-in admin, and the Vapi webhook requires
its secret (`test/security/anonymous_boundary_test.rb`).

### Configuration

Environment variables, or Rails credentials under `vapi.*`. Never commit any of these values.

| Setting | Env var / credential | Used for |
|---|---|---|
| Webhook secret (≥ 16 chars) | `VAPI_SERVER_SECRET` / `vapi.server_secret` | `X-Vapi-Secret` on every webhook; no default |
| Public key (restricted) | `VAPI_PUBLIC_KEY` / `vapi.public_key` | The browser console's web calls |
| Development assistant id | `VAPI_DEV_ASSISTANT_ID` / `vapi.dev_assistant_id` | The console and `vapi:check` |
| Private key | `VAPI_PRIVATE_KEY` / `vapi.private_key` | `vapi:check` only (read-only API calls) |
| Expected tunnel host (optional) | `VAPI_EXPECTED_HOST` | `vapi:check` pins the webhook host |
| Twilio (optional) | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` | SMS confirmations; the job no-ops without them |

The Vapi assistant is configured by hand from the repository (`config/vapi/assistant.json`, `config/vapi/assistant.md`,
`config/vapi/tools.json`, `docs/voice_agent/system_prompt.md`); there is no write automation. `bin/rails vapi:check` compares the
live development assistant with those files (read-only). It checks configuration, not the requests Vapi actually sends to the model.

### Live calls

Vapi must reach the webhook over HTTPS, e.g. `ngrok http 3000` with the assistant's server URL set to
`https://<host>/api/vapi/webhooks`. The procedure, preflight and what the console should show are in
[docs/voice_agent/first_live_call.md](docs/voice_agent/first_live_call.md). After a call, `bin/rails calls:last` prints a
payload-free summary (tool calls, versions, turn evidence, order) that is safe to paste.

## Tests, evaluation and checks

```
bin/rails test                                               # full suite (about 400 tests)
bin/rails test test/baseline/reliability_characterization_test.rb   # R01–R24 reliability rules
bin/rails test test/baseline/live_call_replay_test.rb        # replays of real recorded calls
bin/rails test test/services/evaluation                      # evaluation harness + evidence freshness
bin/rails baseline:verify                                    # frozen Phase 0 tests against the portfolio-baseline tag
RAILS_ENV=test bin/rails evidence:generate                   # rebuild docs/phase1/evidence/*.json
RAILS_ENV=test bin/rails evidence:suite                      # record suite counts in the evidence
bin/rails vapi:check                                         # live assistant vs repository (read-only)
bin/rubocop; bin/brakeman --no-pager; bin/bundler-audit; bin/importmap audit
```

- **Reliability suite** (R01–R24): the Phase 0 characterization tests, each rewritten to the intended behaviour (R21/R22 retired
  with the removed adapter; R24 is the confirmation gate).
- **Replays**: real calls recorded in Phase 0 and in live testing, replayed through the webhook (verbatim, adapted to the current
  contract, and dangerous variants), plus structure-only copies of live `submit_order` webhooks
  (`test/fixtures/files/vapi/`) used to check the confirmation gate against real payloads.
- **Evaluation harness** (`app/services/evaluation`): scripted conversations — prefixes verbatim from a recorded call, then
  deliberate variations — run through the real server path in a rolled-back transaction. It separates what the assistant *claimed*,
  which tool calls the server *received*, which *mutated* the cart, and the resulting *authoritative order*. Results are committed
  in [docs/phase1/evidence/](docs/phase1/evidence/); a test fails if they go stale. No model or Vapi call is involved.

## Documentation

- [docs/phase1/PLAN.md](docs/phase1/PLAN.md) — the Phase 1 plan and its acceptance criteria;
  [ACCEPTANCE.md](docs/phase1/ACCEPTANCE.md) — status against them;
  [EXECUTION_LOG.md](docs/phase1/EXECUTION_LOG.md) — what was built, step by step;
  [CONFIRMATION_PROPOSAL.md](docs/phase1/CONFIRMATION_PROPOSAL.md) — the confirmation design and what was implemented.
- [docs/voice_agent/verification_log.md](docs/voice_agent/verification_log.md) — every live call and live check, with what it does
  and does not show; [system_prompt.md](docs/voice_agent/system_prompt.md) — the prompt the assistant runs.
- Stale, not yet updated for Phase 1: `docs/voice_agent/tools.md`, `vapi_setup.md` and parts of `local_setup.md` still describe
  the removed `api/voice` layer. The current tool definitions are `config/vapi/tools.json`; the assistant checklist is
  `config/vapi/assistant.md`.

## Known limitations

- Live testing (nine Phase 1 browser calls) found the agent submitting before the caller answered (2 of 4 calls that reached submission —
  the reason for the confirmation gate), announcing tool calls it never made, speaking its reasoning, and stacking fillers. Only the
  first is prevented server-side; the others are visible in the console, not fixed. One compliant call is not a rate.
- The gate's refusal path is verified against recorded real payloads and once live (Phase 2, Vapi/DB call #20: the normal
  assistant submitted with no caller turn and was refused). Two deliberate fault-injection attempts did not produce one.
- The gate reads the order of Vapi's conversation history, which can lag what the model received: against one recorded call
  (Call #2) it refuses an order the caller had confirmed. It fails closed (no wrong order); not fixed.
- The model's reasoning effort is not a controllable variable through the assistant configuration (Vapi's requests did not follow
  it).
- The browser public key is not restricted in the Vapi dashboard (any origin, any assistant, transient assistants allowed; owner-
  reported 2026-10-01). `config/vapi/assistant.md` describes the intended restrictions; they were never applied.
- Not built: payments, multiple restaurants, a second voice provider, call transfer, a real-phone SMS test, deployment.

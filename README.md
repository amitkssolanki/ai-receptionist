# AI Restaurant Receptionist

An AI voice receptionist for a single restaurant: answers calls 24/7, answers menu questions, takes orders (pickup or delivery), suggests upsells, confirms the order back before submitting, transfers to a human when needed, and sends an SMS confirmation. Built as a single-restaurant pilot, not yet a multi-tenant product.

## Architecture

This app is deliberately split into two halves that don't overlap:

- **The voice pipeline** (answering the phone, speech-to-text, text-to-speech, turn-taking/interruptions) is **not built here**. That's handled by a dedicated voice AI platform (Retell AI or Vapi — see [docs/voice_agent](docs/voice_agent)), with Twilio for telephony. Rebuilding real-time audio infrastructure from scratch would be reinventing a very hard, already-solved problem.
- **This Rails app is the business-logic brain**: menu data, order lifecycle, SMS confirmations, the admin dashboard, and the webhook API the voice platform calls mid-call via function-calling. It talks to the voice platform over fast JSON, never raw audio.

```
Caller ⇄ Twilio ⇄ Retell/Vapi (voice pipeline, LLM, STT/TTS) ⇄ this Rails app (api/voice/*)
                                                                        │
                                                                 admin dashboard (Devise)
```

### Data model

`Restaurant` owns everything else, scoped by `restaurant_id` even though there's only one restaurant today — that scoping is there so a second location isn't a rewrite later.

- `MenuCategory` → `MenuItem` → `MenuItemModifier` (add-ons like "add bacon") and `MenuItemUpsell` (self-join for "suggest alongside this item" pairings)
- `Customer`, identified by phone number
- `Order` → `OrderItem` (snapshots modifier names/prices at order time, so later menu edits don't rewrite history)
- `CallLog`, one per phone call, optionally linked to the `Order` it produced
- `User` — admin dashboard login (Devise), one per restaurant

### Voice webhook API (`app/controllers/api/voice/`)

The function-calling tools a voice platform invokes mid-call: call start, menu lookup, cart add/update/remove, get cart, submit order, transfer to human, call end. Full request/response shapes, JSON schemas ready to paste into a platform's tool config, and the system prompt are in [docs/voice_agent](docs/voice_agent).

Authenticated via a shared-secret bearer token (`VOICE_WEBHOOK_SECRET`), and deliberately platform-agnostic — the same endpoints work regardless of whether Retell AI or Vapi ends up being the platform of choice.

## Setup

### Prerequisites

- Ruby 3.4.7 (see `.ruby-version`; this repo's `.rvmrc` auto-selects the `ruby-3.4.7@ai-receptionist` RVM gemset if you use RVM)
- PostgreSQL running locally (e.g. Postgres.app)

```
bundle install
bin/rails db:create db:migrate db:seed
```

Seeding creates one restaurant ("Taj Zayka", open 24/7) with a full menu (pizzas, sides, drinks, combos — see `db/seeds.rb`) and one admin login:

- Email: `admin@example.com`
- Password: `password123`

(Local dev only — never use these anywhere real.)

### Running locally

```
bin/dev
```

Not `bin/rails server` — `bin/dev` also runs the Tailwind watcher, so CSS changes show up without a manual rebuild. Visit `http://localhost:3000`.

To expose the app to a real voice platform over the internet (via ngrok, for free), see [docs/voice_agent/local_setup.md](docs/voice_agent/local_setup.md).

### Environment variables

| Variable | Required | Purpose |
|---|---|---|
| `VOICE_WEBHOOK_SECRET` | Recommended | Bearer token the voice platform must send on every `api/voice/*` request. Defaults to `dev-secret-change-me` outside production (always fails in production if unset). |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` | Optional | SMS order confirmations. `OrderConfirmationSmsJob` silently no-ops if any are missing — safe to leave unset in early dev. |

### Tests

```
bin/rails test
```

Covers the voice webhook API end-to-end (call lifecycle, cart building, order submission, transfer) and model business logic (business-hours checks, upsell pairing validations).

## Project status

This was built out phase-by-phase; see the original plan and phase-by-phase git history for the full trail. Roughly:

- ✅ Rails foundation, admin dashboard
- ✅ Conversation/prompt design ([docs/voice_agent](docs/voice_agent))
- ✅ Voice webhook API
- ✅ Business logic (hours awareness, upsells, availability)
- ⏳ **Next**: pick a voice platform (Retell AI vs. Vapi) by actually testing both against this app locally, then go live

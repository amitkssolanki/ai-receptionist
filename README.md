# AI Restaurant Receptionist

An AI voice receptionist for a single restaurant (currently "Taj Zayka", open 24/7 in the seed data): answers calls, answers menu questions, takes orders (pickup or delivery), suggests upsells, confirms the order back before submitting, transfers to a human when needed, and sends an SMS confirmation. Built as a single-restaurant pilot, not yet a multi-tenant product.

**Status**: the voice platform (Vapi) has been chosen and wired up end-to-end — a full test call (menu question → add item with a modifier → read-back confirmation → submit) has been verified working, both in the call transcript and independently in the database. See [Project status](#project-status) below for what's left.

## Architecture

This app is deliberately split into two halves that don't overlap:

- **The voice pipeline** (answering the phone, speech-to-text, text-to-speech, turn-taking/interruptions, the LLM itself) is **not built here**. That's [Vapi](https://vapi.ai), with Twilio or a Vapi-hosted number for telephony. Rebuilding real-time audio infrastructure from scratch would be reinventing a very hard, already-solved problem.
- **This Rails app is the business-logic brain**: menu data, order lifecycle, SMS confirmations, the admin dashboard, and the webhook API Vapi calls mid-call via function-calling (tool calls) and server events (call start/end). It talks to Vapi over fast JSON, never raw audio.

```
Caller ⇄ Twilio/Vapi number ⇄ Vapi (voice pipeline, LLM, STT/TTS) ⇄ this Rails app (api/vapi/webhooks)
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

### Admin dashboard (`app/controllers/admin/`)

Devise-authenticated, one login per restaurant. Covers:

- **Menu** — categories, items, modifiers, and upsell pairings (checkboxes on an item's edit page)
- **Orders** — list/detail, with a status dropdown (pending → confirmed → preparing → ready → completed/cancelled)
- **Call Logs** — list/detail, including transcript and recording playback once a platform sends them
- **Settings** — restaurant name, phone number, address, timezone, and business hours (7 plain-text day fields, `"11:00-21:00"` or `"closed"`)

### Voice integration (`app/controllers/api/`)

There are two layers here, and it's worth understanding why:

- **`api/voice/*`** — a platform-agnostic set of endpoints (call start, menu lookup, cart add/update/remove, get cart, submit order, transfer, call end) built before a specific platform was chosen. Auth via a shared-secret bearer token (`VOICE_WEBHOOK_SECRET`).
- **`api/vapi/webhooks`** — the actual adapter Vapi talks to. Vapi doesn't template a call id into per-tool URLs the way `api/voice/*` assumed; instead it POSTs every event (call start, every tool call, call end) to **one single webhook URL**, with the call's identity in the JSON body, and expects tool responses back in Vapi's specific `{"results": [...]}` shape. This controller translates that into calls against the same underlying models (`Restaurant#voice_menu_json`, `Order#cart_summary`, etc.) — there's one source of truth for the business logic, just two thin transport layers on top of it. Auth via the `X-Vapi-Secret` header (`VAPI_SERVER_SECRET`).

Full docs, the system prompt, and step-by-step Vapi dashboard configuration are in [docs/voice_agent](docs/voice_agent) — see that section below.

## Setup

### Prerequisites

- Ruby 3.4.7 (see `.ruby-version`; this repo's `.rvmrc` auto-selects the `ruby-3.4.7@ai-receptionist` RVM gemset if you use RVM)
- PostgreSQL running locally (e.g. Postgres.app)

```
bundle install
bin/rails db:create db:migrate db:seed
```

Seeding creates one restaurant ("Taj Zayka", open 24/7) with a full menu — pizzas, sides, drinks, and combos (entree + side + drink bundles) — see `db/seeds.rb` for the exact items/prices/modifiers — and one admin login:

- Email: `admin@example.com`
- Password: `password123`

(Local dev only — never use these anywhere real.)

### Running locally

```
bin/dev
```

Not `bin/rails server` — `bin/dev` also runs the Tailwind watcher, so CSS changes show up without a manual rebuild. Visit `http://localhost:3000` and log in with the seeded admin above.

### Connecting a real voice platform

To let Vapi (or any platform) actually call this app, you need a publicly reachable URL. The full walkthrough — upgrading ngrok, starting the tunnel, and the Vapi dashboard configuration (system prompt, the 7 custom tools, server URL/secret, phone number) — is in [docs/voice_agent/local_setup.md](docs/voice_agent/local_setup.md) and [docs/voice_agent/vapi_setup.md](docs/voice_agent/vapi_setup.md). Short version:

```
bin/dev                              # rails app on :3000
ngrok http 3000                      # separate terminal
```

Then in Vapi: set the assistant's Server URL to `<ngrok-url>/api/vapi/webhooks`, set a Server URL Secret (matches `VAPI_SERVER_SECRET`, or use the `dev-secret-change-me` default locally), paste in the system prompt, and add the 7 tools. Full details in the two docs above.

### Environment variables

| Variable | Required | Purpose |
|---|---|---|
| `VAPI_SERVER_SECRET` | Recommended | Value Vapi must send in the `X-Vapi-Secret` header on every `api/vapi/webhooks` request. Defaults to `dev-secret-change-me` outside production (always fails in production if unset). |
| `VOICE_WEBHOOK_SECRET` | Recommended | Same idea, for the generic `api/voice/*` endpoints (`Authorization: Bearer <secret>`). Same default behavior. |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` | Optional | SMS order confirmations. `OrderConfirmationSmsJob` silently no-ops if any are missing — safe to leave unset in early dev. |

### Tests

```
bin/rails test
```

23 tests as of this writing. Covers both voice integration layers end-to-end (call lifecycle, cart building, order submission, transfer, tool-call dispatch simulating Vapi's actual payload shapes), admin controllers (restaurant settings), and model business logic (business-hours checks, upsell pairing validations).

## docs/voice_agent

- [system_prompt.md](docs/voice_agent/system_prompt.md) — the actual system prompt, paste-ready (no placeholders) for Taj Zayka
- [tools.md](docs/voice_agent/tools.md) — the 7 function-calling tools' name/description/JSON-schema parameters, platform-agnostic
- [vapi_setup.md](docs/voice_agent/vapi_setup.md) — exact Vapi dashboard steps: server URL/secret, attaching tools, phone number, testing
- [local_setup.md](docs/voice_agent/local_setup.md) — ngrok setup, cost-management notes for the free-trial bake-off, troubleshooting

## Project status

- ✅ Rails foundation, admin dashboard (including restaurant settings/business hours)
- ✅ Conversation/prompt design
- ✅ Voice webhook API (generic + Vapi-specific adapter)
- ✅ Business logic (hours awareness, upsells, availability)
- ✅ Vapi chosen and connected — a full order flow (menu question → add item with modifier → confirm → submit) has been verified end-to-end via a live test call, both in the transcript and in the database
- ⏳ **Next**: more test scenarios (delivery orders, transfer-to-human, unavailable items), then a real-phone-number test (vs. the browser-based test call used so far) to validate the caller's real phone number is captured correctly, then decide on deploy/hosting

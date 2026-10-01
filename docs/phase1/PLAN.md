# Phase 1 Plan — Reliability + Live Voice Test Console (revision 2)

Project: `ai-receptionist` (Rails 8.1 + Vapi). Baseline: tag `portfolio-baseline` (`257a9e7`).
Principle: **The model proposes. The server decides.** The dashboard makes that visible and is a read-only observer.

## 0. What changed from revision 1

First-class work is unchanged: the live console, `ToolInvocation`, server-owned read-back/confirmation, cart
versioning, the R01–R23 reliability suite, live-call replay, and live verification. The architecture and the
17-step sequence are unchanged; supporting pieces were simplified:

| Area | Revision 1 | Revision 2 |
|---|---|---|
| Browser → Vapi auth | Server-minted JWT per console session + token endpoint | **Restricted public key** (allowed origins + allowed assistant id + no transient assistants), stored in Rails credentials, rendered only on the Devise-protected console page. No token endpoint, no JWT code |
| Vapi config-as-code | `vapi:diff` + `vapi:push` (API writes; PATCH semantics unknown) | **Repo files are the source of truth, dev assistant is set up by hand from them, and a read-only `bin/rails vapi:check` detects drift** (tools attached, names, parameter schemas, prompt, serverMessages, max duration, server URL). No API writes |
| SMS | Send-once status columns, row locking, status on the board | **Guard only**: enqueue on the pending→confirmed transition (comes from idempotent submit), skip non-E.164 numbers, itemized body. No new columns; not shown on the console |
| Generic REST adapter (`api/voice/*`) | Kept thin, parity tests, Idempotency-Key header | **Deleted** (no live consumer). R21/R22 retired with a documented reason; their rules are covered on the Vapi path (R02/R03/R04/R12) |
| Webhook auth | HMAC credential + timestamp window | **Strong random static secret** (`X-Vapi-Secret`), no default outside the test env. HMAC deferred to Phase 4 as optional hardening |
| Recording playback fix | Presigned redirect | Dropped (player left as-is; documented limitation) |
| Scenario cards in console | Static script drawer | Dropped (Phase 2 may add) |

Estimated Phase 1 effort: **≈ 50–75 h** (was 57–84). Level B overall: **≈ 95–135 h**.

---

## 1. Architecture

```
            ┌──────────── Browser: /admin/console (Devise) ────────────────────────────────────────────┐
 mic/spk ◀─▶│ voice_console Stimulus controller ── @vapi-ai/web ─(WebRTC audio + Daily data channel)─┐ │
            │  • CONVERSATION panel ◀── Vapi client messages      [source: VAPI, non-authoritative]    │ │
            │  • ORDER BOARD + SERVER EVENTS ◀── Turbo Streams / Action Cable [source: RAILS, authoritative]
            └───────────▲────────────────────────────────────────────────────────────────────────────┼─┘
                        │ page render: restricted public key, dev assistant id, signed console token   │
                        │                                                                              ▼
┌──────────────── Rails ┴─────────────────────────────────────┐        ┌──────────── Vapi ─────────────┐
│ Api::Vapi::WebhooksController (static secret, envelope only)│◀───────┤ STT → LLM → TTS                │
│   ├▶ CallLifecycle   start / transfer / finish              │ HTTPS  │ serverMessages: status-update, │
│   └▶ Voice::ToolRunner idempotency · args · errors · timing │───────▶│ tool-calls, end-of-call-report │
│        └▶ OrderTaking (cart, read-back, submit) · MenuCatalog│        └────────────────────────────────┘
│ ToolInvocation · Order · CallLog (Postgres)                 │
│ ConsoleBroadcaster ─ after commit ─▶ Turbo::StreamsChannel ─┼─▶ Action Cable (async dev / solid_cable prod)
│ OrderConfirmationSmsJob (guarded; skipped for web calls)    │
└─────────────────────────────────────────────────────────────┘
```

**Flow A — conversation (audio never touches Rails).** Mic → WebRTC → Vapi STT → LLM → TTS → speaker. Vapi pushes
client messages (`transcript` partial/final, `speech-update`, `status-update`, `tool-calls`, `user-interrupted`,
`hang`) over the data channel; the Stimulus controller renders them, labeled **VAPI · client**. The persisted record
is the end-of-call report (transcript + messages) stored on `CallLog`.

**Flow B — business events.** Vapi POSTs `tool-calls` → `ToolRunner`, in one transaction: insert `ToolInvocation`
(unique per call + toolCallId) → coerce arguments → `OrderTaking` → store result/status/cart versions/duration →
commit → `ConsoleBroadcaster` (event row → order board → call status) → respond `{results:[…]}`. `status-update` and
`end-of-call-report` go through `CallLifecycle` and broadcast the same way.

**Authority**

| Information | Authoritative | Displayed as |
|---|---|---|
| Audio, STT, what the agent said | Vapi | Conversation panel (live); `CallLog.messages` afterwards |
| Tool call requested | Vapi | Pending placeholder row (client) |
| Tool call executed: args received, result, error code, duration | **Rails `ToolInvocation`** | Server events |
| Cart lines, modifiers, prices, totals, `cart_version`, read-back state, order status | **Rails `Order`/`OrderItem`** | Order board (server only) |
| Call lifecycle, transfer, ended reason, cost | Rails `CallLog` (fed by Vapi server events) | Status strip |
| Mic / WebRTC / Action Cable connection | Browser | Local indicators |
| Who may start a call | Rails (Devise) + Vapi key restrictions | — |

**Authentication**
- Console page and Action Cable: Devise (cable connection rejects unauthenticated users); Turbo stream names signed.
- Vapi → Rails: `X-Vapi-Secret` with a strong random value from credentials/ENV; required in every environment
  except `test` (no public default). Constant-time compare (existing).
- Browser → Vapi: public key restricted to `allowedAssistantIds: [dev assistant]`, `allowedOrigins: [console
  origins]`, `allowTransientAssistant: false`. Origin checks only bind browsers, so cost exposure is bounded by the
  assistant restriction, `maxDurationSeconds: 300`, a Vapi spend limit if the account offers one (verify), and
  rotating the key after demo sessions. Documented as an accepted portfolio-scope tradeoff.

---

## 2. Dashboard design

Routes: `/admin/console` (new call) and `/admin/console/calls/:id` (observe an in-progress call / review a past one).
Own dark `console` layout (Tailwind, monospace for technical data).

**A. Conversation — source VAPI (client); live only in the tab hosting the call**
- Rows: `T+mm:ss` (browser clock from `call-start`), CUSTOMER/AGENT, text. Partials dim/italic, replaced in place by
  the final for that turn.
- Header: status (idle/connecting/live/ended/failed), elapsed, Vapi connection, mic level (`local-volume-level`),
  agent level (`volume-level`), agent-speaking indicator (`speech-update`).
- **Unbacked-claim marker (labeled "heuristic")**: an agent final line matching a claim pattern (added / I'll add /
  removed / changed / updated your order) with **no server event that changed `cart_version`** between −2 s and +8 s
  (browser receipt clock) is marked ⚠ and linked to the board. Display only.
- Review mode renders the persisted end-of-call messages and applies the same marker.

**B. Order board — source SERVER only** (`_order_board` partial rendered from the DB; full snapshot every time)
- Order #, status badge (CART OPEN / CONFIRMED 🔒 / ABANDONED / …), fulfillment, delivery address.
- Lines: qty × item, modifiers with prices, line subtotal; total.
- `cart v3`; read-back: `not delivered` / `delivered for v3 at T+01:43` / `STALE: cart v4, read-back v3`.
- Confirmation: `awaiting read-back` → `ready to submit (v3)` → `submitted v3 at …` → `duplicate submit absorbed ×1`.

**C. Server events — source SERVER (`ToolInvocation` + lifecycle rows)**
- Columns: T+ (server `started_at` relative to call start), tool, arguments (compact, ids resolved to names), result
  summary, status (✓ ok / ⛔ rejected + code / ✖ error `internal_error`), cart change `v0→v1`, server ms, observed
  latency (browser receipt of the server row minus browser receipt of Vapi's `tool-calls` for the same id).
- Pending rows: on Vapi's client `tool-calls`, insert a placeholder with id `tool_call_<toolCallId>`; the server
  broadcast uses the same id and Turbo's same-id de-duplication replaces it.
- Row expansion: full arguments and the exact result returned to the model (including the speakable error message).
- Replayed deliveries: "↺ replayed ×N (stored result returned)".

**Never shown** (automated scan test over rendered pages and every broadcast partial): private key, webhook secret,
raw Vapi payloads, `monitor` / `controlUrl` / `listenUrl` / `webCallUrl` / `transport` URLs, recording URLs, org id,
exception classes/messages (kept in `ToolInvocation.error_class` for logs only). The *public* key is present on the
console page by design (restricted; see §1).

**Synchronization**
1. B and C render from committed DB state, broadcast in a fixed order from one place.
2. Board/status broadcasts are full snapshots; event rows have stable DOM ids; on Action Cable `connected`
   (including reconnects) the page reloads the `#call-state` turbo-frame from the DB → missed broadcasts self-heal.
3. A is never merged into server state — shown alongside on a shared browser-receipt time axis with source badges.
   Server timestamps (server clock) and browser receipt times (browser clock) are never subtracted from each other.

---

## 3. Reliability rules (R01–R23)

Tool results remain a flat string containing JSON: `{"ok":true,…}` or
`{"ok":false,"error":{"code":"…","message":"<speakable guidance>"}}`. The Vapi `error` field is not used.
Codes: `invalid_arguments`, `unknown_tool`, `no_active_call`, `menu_item_unavailable`, `invalid_modifier`,
`quantity_out_of_range`, `large_order_requires_staff`, `restaurant_closed`, `cart_empty`,
`delivery_address_required`, `item_not_in_cart`, `readback_required`, `cart_changed_since_readback`,
`order_already_submitted`, `internal_error`.

| # | Rule | Authority | State | Responsible | Behavior | Test |
|---|---|---|---|---|---|---|
| R01 | No submit without server read-back | Service + DB | `orders.cart_version`, `read_back_version`, `read_back_at` | `OrderTaking#submit` | No read-back at current version → `readback_required` | Submit with no `get_cart` → rejected, status unchanged |
| — | Stale read-back rejected | Service | + `cart_version` argument | `OrderTaking#submit` | Arg ≠ current or read-back ≠ current → `cart_changed_since_readback` (returns current version) | add → get_cart(v1) → add(v2) → submit(v1) → rejected |
| — | Cart versioning | Service + DB | `cart_version` int default 0 | `OrderTaking` | +1 inside every mutating transaction; returned in every cart result | Each mutation +1 exactly; reads never |
| R03 | Submitted orders immutable | Model + service | `status` | `Order#cart_open?`, `OrderTaking` | Mutations only while `pending` → else `order_already_submitted` | add/update/remove after submit or `preparing` → rejected, total unchanged |
| — | Admin can't reopen | Model | `status` | `Order` transition map, `Admin::OrdersController` | No transition *to* `pending`; `completed`/`cancelled`/`abandoned` terminal | PATCH confirmed→pending → error |
| R02 | Duplicate submit safe | Service + row lock | `status`, `placed_at` | `OrderTaking#submit` (`order.lock!`) | Confirmed → same summary + `already_submitted: true`, no changes, no job | 2nd submit: `placed_at` unchanged, 1 SMS job enqueued total, fulfillment unchanged |
| R04/R05 | Invalid modifiers rejected | Service | item's modifiers | `OrderTaking#add_item` | Foreign/nonexistent id → `invalid_modifier` listing valid modifier names | Both cases → rejected, nothing inserted |
| R06 | Invalid/unavailable/foreign item | Service | restaurant-scoped available items | `OrderTaking#add_item` | `menu_item_unavailable`, speakable, no SQL | 3 cases → code only |
| R07 | Quantity limits | Args + service | — | `Voice::ToolArguments`, `OrderTaking` | Integer 1–20 else `quantity_out_of_range`; "two" → `invalid_arguments` | 0, 1, 20, 21, −3, "two", 2.5 |
| R07 | Large order | Service | total item count | `OrderTaking` | Adding beyond 30 total items → `large_order_requires_staff` (advise transfer) | 30 ok, 31 rejected |
| R08 | Closed hours | Service | `Restaurant#open_now?` | `OrderTaking#add_item`, `#submit` | `restaurant_closed` + today's hours | Closed → add and submit rejected |
| R09 | True 24h | Model | `business_hours` | `Restaurant#open_now?` | `"00:00-24:00"` / `"24h"` = all day; seeds updated | 23:59:30 → open |
| R10 | Malformed arguments | Adapter boundary | per-tool schema | `Voice::ToolArguments` | Missing/wrong type/bad JSON/bad enum → `invalid_arguments` naming the field | One test per tool + bad JSON |
| — | No raw exception text | Adapter | — | `Voice::ToolRunner` | Unexpected exception → rollback, log with ids, store `error_class`, return `internal_error` ("offer a transfer") | Simulated failure → no exception text |
| R16 | Atomic add-to-cart | DB | transaction + order lock | `OrderTaking` | Order + call link + item + total + version commit together | Item insert failure → no order, no link |
| R17 | Abandoned carts | Service | `status` += `abandoned` | `CallLifecycle#finish` | Open cart at call end → `abandoned` (items kept) | End with items → abandoned |
| R12 | Transfer precedence | Service | `call_logs.transferred_at`, `transfer_reason` | `CallLifecycle` | transferred > completed > abandoned; reason in its own column | transfer → end → still transferred, reason kept |
| R13 | Duplicate call-start | DB unique index | `external_call_id` | `CallLifecycle#start` | Create-or-find (handle `RecordNotUnique` and the uniqueness `RecordInvalid`); always 200 | Sequential + simulated race → 1 row, 200 |
| R14 | Duplicate toolCallId | DB unique index | `tool_invocations (call_log_id, tool_call_id)` | `Voice::ToolRunner` | Redelivery returns stored result, `replay_count += 1`, no re-execution | Same id twice → 1 item, identical result; concurrent duplicate test |
| R15 | Semantic duplicates | **Not prevented** (by design) | — | Read-back protocol + dashboard | Both execute; server read-back shows qty 2; dashboard notes "same item added twice within 5 s" | Documented test: both execute, read-back lists 2 |
| R18 | SMS guard | Job | E.164 check | `OrderConfirmationSmsJob` | Enqueued only on pending→confirmed; returns early for non-phone numbers; itemized body | Web call → no send; phone → itemized body |
| R19/R11 | Already safe | — | — | — | Keep | Keep |
| R20 | Webhook auth | Controller | secret in credentials/ENV | `Api::Vapi::WebhooksController` | Missing/wrong → 401; no default secret outside `test` | Missing/wrong → 401; unset secret in dev → 401 (not the README default) |
| R21/R22 | Generic adapter | **Retired** | — | — | `api/voice/*` deleted in Step 2; rules covered by R02/R03/R04/R12 on the Vapi path | Retirement noted in the R-suite file and commit message |
| R23 | Restaurant resolution | Service | signed console token, dialed number | `CallLifecycle#resolve_restaurant` | Valid signed console token → dialed number → dev-only default flag → otherwise refuse (no CallLog, warning log; tools return `no_active_call`) | Two restaurants + token → correct; no token → refused; forged token → refused |

---

## 4. `tool_invocations`

| Column | Type | Purpose |
|---|---|---|
| `id` | bigint | DOM id `tool_invocation_<id>` |
| `call_log_id` | FK not null | Call |
| `order_id` | FK nullable | Order touched |
| `tool_call_id` | string not null | Vapi `toolCall.id` |
| `source` | string | `vapi` \| `replay` |
| `tool_name` | string not null | |
| `arguments` | jsonb | As received/parsed (cap 4 KB) |
| `result` | jsonb | Exactly what the model received |
| `status` | string | `ok` \| `rejected` \| `error` |
| `error_code` | string | Structured code |
| `error_class` | string | Unexpected failures only; never broadcast |
| `cart_version_before`, `cart_version_after` | int | Mutation evidence ("v0→v1"); used by the claim marker |
| `vapi_requested_at` | datetime(ms) | Vapi message `timestamp` |
| `started_at`, `finished_at`, `duration_ms` | | Server timing |
| `replay_count` | int default 0 | Duplicate deliveries absorbed |

Indexes: unique `(call_log_id, tool_call_id)`; `(call_log_id, started_at)`. No persisted "in progress": the row is
inserted and completed in the same transaction as the business change; a concurrent duplicate blocks on the unique
index, then reads the committed row. On unexpected failure the transaction rolls back and an `error` row is written
afterwards outside it.

Also: `call_logs` += `console_session_key` (indexed), `transferred_at`, `transfer_reason`, `ended_reason`,
`duration_seconds`, `cost_usd` (decimal 10,4), `assistant_version`, `messages` (jsonb, sanitized end-of-call
messages). `orders` += `cart_version`, `read_back_version`, `read_back_at`; status value `abandoned`.

Uses: idempotency (unique key + stored result) · debugging (args/result/code/timing per call) · live dashboard
(broadcast after commit) · replay (compare results; `source: replay`) · evaluation (tool sequence + version
changes) · portfolio evidence (real latency/error data). Not event sourcing: orders remain the source of truth.

---

## 5. Real-time

- `app/channels/application_cable/connection.rb`: identify the Devise user via `env["warden"]`; reject otherwise.
- Built-in `Turbo::StreamsChannel`, signed stream names. No custom channels.
- Streams: `[:console_session, key]` (bootstrap; `key` generated when the console page renders) and
  `[call_log, :console]` (everything for one call).
- Broadcasts: synchronous, **after commit**, from `ConsoleBroadcaster` only, fixed order, failures logged and never
  propagated to the tool response.

| Event | When | Action | Target |
|---|---|---|---|
| `call_attached` | `CallLifecycle#start` commits a console call | `replace` | `#console-call` on the session stream → call panels + nested `turbo_stream_from [call_log, :console]` |
| `tool_invocation` | `ToolRunner` commit (new/replayed) | `append` (same-id de-dup) / `replace` | `#events` |
| `order_board` | Any invocation touching an order; lifecycle changes | `replace` | `#order-board` |
| `call_status` | start / transfer / finish | `replace` | `#call-status` |

- Browser disconnect: the Vapi call continues (Daily, not Cable). Cable reconnects → frame reload backfills. Closing or
  reloading the *hosting* tab ends the web call; show a `beforeunload` warning while live.
- Opened after start (another tab): `/admin/console/calls/:id` renders server state from the DB and subscribes; the
  live transcript is unavailable there (Vapi client messages only reach the hosting browser) — the page says so; the
  persisted transcript appears after the end-of-call report.
- Merge: separate panels, source badges, shared browser-receipt time axis. The only join is the toolCallId shared by a
  pending row and its server row, and the server row always wins. Vapi's `tool-calls-result` client message is ignored.

---

## 6. Vapi configuration (simplified)

- **Leave the baseline assistant `8f2053ae…` (v4) untouched** — it is the "before" config for Layer 3a.
- **Repo is the source of truth:** `docs/voice_agent/system_prompt.md` + `config/vapi/tools.json` (the exact function
  definitions to paste into Vapi) + `config/vapi/assistant.md` (checklist of every dashboard setting:
  model/STT/voice as baseline, `serverMessages` = `status-update`, `tool-calls`, `end-of-call-report`;
  `maxDurationSeconds: 300`; server URL + secret; no `backoffPlan`).
- **Create the dev assistant by hand** from those files (the user does this in the Vapi dashboard, following
  `docs/voice_agent/vapi_setup.md`).
- **Drift check (read-only):** `bin/rails vapi:check` GETs the dev assistant and its tools using the private key from
  credentials, and fails if tool count/names/parameter schemas, prompt text (normalized), `serverMessages`,
  `maxDurationSeconds` or server URL host differ from the repo. Run before every live session. Directly guards the
  call-#6 failure class (assistant with zero tools).
- **Parity test (CI, no network):** tool names and parameter keys in `config/vapi/tools.json` exactly match
  `Voice::ToolRunner` handlers and `Voice::ToolArguments` schemas.
- **clientMessages:** set per call via `vapi.start(assistantId, { clientMessages: [...], metadata: {...} })` —
  `transcript`, `speech-update`, `status-update`, `tool-calls`, `user-interrupted`, `hang`.
- **metadata:** `console_token` = `Rails.application.message_verifier(:vapi_console)` signed
  `{restaurant_id, session_key}`, expiring in 15 minutes. Arrival at the webhook under `call.assistantOverrides.metadata`
  is high-confidence (field in the spec; overrides observed in baseline payloads) — confirm on the first live call.
- **Tools:** `get_menu` (compact) + new `get_menu_item`; `add_to_cart` result includes `confirmation_text` and the
  item's pairings; `get_cart` returns `readback_text` + `cart_version`; `submit_order` requires `cart_version`; fix
  the `"Description: "` typo; synchronous tools.
- **Prompt:** read `readback_text` verbatim; state a change only after its tool result (use `confirmation_text`); if a
  reply to an offer is unclear ask yes/no, and if still unclear do not add; call `get_menu_item` before discussing
  modifiers; offer at most 3 options; offer transfer on `large_order_requires_staff` / `internal_error`.
- **Public key restrictions** configured by hand in the Vapi dashboard; verification recorded in the log.
- Unknowns to verify and log (not assume): metadata arrival path, `tool-calls-result` shape (unused anyway),
  web-call transfer (out of scope), whether the account has a spend limit.

---

## 7. Menu performance

- `MenuCatalog.overview` → categories → items `{id, name, price, customizable}` (no descriptions/modifiers).
- `MenuCatalog.item(id)` → description, modifiers (id, name, price), pairings.
- Preload once with scoped associations (replace the `.available` scope calls inside loops at `restaurant.rb:36,43`).

| Measure | Baseline | Target | How |
|---|---|---|---|
| `get_menu` queries | 53 | ≤ 3, constant when the menu doubles | `assert_queries_count` on seed menu and doubled menu |
| `get_menu` bytes | 4,554 | ≤ 1,600 (seed menu) | Size assertion |
| `get_menu_item` queries | — | ≤ 4 | Test |
| Server time | 267 ms (one live sample) | Median of 50, before (tag) vs after | `bin/rails runner` benchmark script |
| Voice behavior | ~50 s menu recital | Qualitative + TTS characters per call | Live console runs (small N, reported as observations) |

---

## 8. Evaluation

- **Layer 1 (CI):** R01–R23 characterization tests move into the repo and are rewritten to the new expected behavior
  keeping their R-IDs (R21/R22 retired with reason). Plus service unit tests, argument-schema tests, `ToolRunner`
  idempotency/concurrency tests, broadcast tests, admin transition tests, tools.json parity test, secrets scan.
  Frozen originals stay under `test/fixtures/files/baseline/`; `bin/rails baseline:verify` runs them against a
  worktree of `portfolio-baseline`.
- **Layer 2 (CI):** (a) call #6 verbatim → abandoned, no order; (b) call #7 verbatim → `submit_order` rejected with
  `invalid_arguments: cart_version` (documents the contract change); (c) call #7 adapted (inject `cart_version` from
  the preceding `get_cart`) → same $16 order; (d) dangerous variants from call #7: `get_cart` removed →
  `readback_required`; add inserted after read-back → `cart_changed_since_readback`.
- **Layer 3a (designed now, run in Phase 2):** prefixes from the fixture's `messagesOpenAIFormatted` after "It should
  be.", after "That should be.", and at call #6's "Let me pull up the menu" with tools present; `gpt-5-mini` minimal;
  baseline (v4 prompt/tools) vs new; N = 20 each; classify next action (tool-backed add / clarifying question /
  claim-without-tool / other).
- **Layer 3b (Phase 2):** 8 scenarios × 5 trials — simple order with modifier; unclear upsell reply; change of mind;
  unknown item; invalid modifier request; large order → transfer; out-of-scope → transfer; delivery without address.

---

## 9. Garlic-knots failure class

Baseline (verbatim): agent offered "garlic knots, fries" → "It should be." → "Sorry, did you mean you want garlic
knots or fries with that?" → "That should be." → "Great. I'll add garlic knots…" → no `add_to_cart` → `get_cart`
returned only the pizza → read back "$16" → "Yes" → submit.

Failure class: the model's spoken account of the order diverges from server state at confirmation time.

```
v0  (no order)
add_to_cart(Margherita, [Extra cheese]) ──▶ v1   confirmation_text "Added 1 Margherita Pizza with Extra cheese. Total $16.00."
[agent says "I'll add garlic knots" — no tool call — board stays v1 — console marks ⚠ unbacked claim]
get_cart ──▶ read_back_version = 1, readback_text "One Margherita Pizza with extra cheese. Total sixteen dollars."
caller: "Yes"
submit_order(cart_version: 1) ──▶ CONFIRMED 🔒 (SMS job enqueued once; skipped for web calls)

Variant A: submit without get_cart                        ──▶ ⛔ readback_required
Variant B: get_cart(v1) → add knots (v2) → submit(v1)      ──▶ ⛔ cart_changed_since_readback
Variant C: agent reads back from memory                    ──▶ not preventable server-side; mitigated by the
           verbatim-readback prompt rule and the console marker; measured in Layer 3a
```

Eliminated: submitting anything not read back from server state at that exact version. Not eliminated (stated in
the case study): spoken claims themselves, and the model's judgment of the caller's "yes" — made visible and measured.
Tests: R01, stale-version, variants A/B (Layer 1), adapted replay (Layer 2), probes (Layer 3a). Live demo: a scripted
console run recreating the unclear upsell reply.

---

## 10. Rails components

| Component | Responsibility |
|---|---|
| `OrderTaking` | `add_item`, `update_quantity`, `remove_item`, `read_back`, `submit`; transactions, order lock, version increments, limits, hours; returns `OrderTaking::Result` (small `Data`) |
| `OrderTaking::Readback` | Deterministic speakable read-back and confirmation text |
| `MenuCatalog` | `overview`, `item(id)`; preloading (replaces `Restaurant#voice_menu_json`) |
| `CallLifecycle` | `start` (resolution, create-or-find), `transfer`, `finish` (precedence, abandoned carts, cost/messages) |
| `Voice::ToolArguments` | Per-tool coercion schemas (plain Ruby hash) |
| `Voice::ToolRunner` | Idempotency → args → dispatch → error containment → timing → `ToolInvocation` → broadcast |
| `ConsoleBroadcaster` | Render partials, ordered broadcast, failure isolation |
| `ToolInvocation` | Log model |
| `Order` / `CallLog` / `Restaurant` | Transition map, `cart_open?`, `abandoned`; new columns; 24 h support |
| `Api::Vapi::WebhooksController` | Envelope only: secret check, route, `{results:[…]}`; no raw-payload logging in production |
| `Admin::ConsoleController` | Console + call review pages; renders public key, assistant id, signed console token |
| `Admin::OrdersController` | Uses the transition map |
| `ApplicationCable::Connection` | Devise auth |
| `voice_console_controller.js` | SDK lifecycle, transcript, pending rows, connection state, claim marker, latency stamps |
| `OrderConfirmationSmsJob` | E.164 guard, itemized body |
| `lib/tasks/vapi.rake` | `vapi:check` (read-only) |
| `lib/tasks/baseline.rake` | `baseline:verify` |
| Deleted | `Api::Voice::*`, their routes and controller tests |

---

## 11. Security

| Issue | Fix |
|---|---|
| Raw exception text | `ToolRunner` containment + codes |
| Payload logging | Drop the full-payload `logger.info` outside development; compact line (type, call id, tool names); `filter_parameters` for `message`, `artifact`, `transcript`, `customer`, `phoneNumber`, `monitor`, `transport` |
| Webhook auth | Strong random secret from credentials/ENV; no default outside `test` |
| Public key | Restricted key (assistant id, origins, no transient); `maxDurationSeconds: 300`; rotate after demos |
| Admin | Existing Devise + restaurant scoping; console and cable require login |
| Unknown browser callers | Web calls without a valid signed console token refused (no DB writes); dev-only default-restaurant flag |
| SMS to unknown numbers | E.164 guard |
| Notes length | ≤ 300 chars (argument schema + model validation) |
| TLS | `assume_ssl` + `force_ssl` in production, `/up` excluded |
| Sign-in brute force | `rate_limit` on a Devise sessions subclass (`create`: 10 / 3 min) |
| Secrets in pages | Automated scan test |

---

## 12. Wireframes

```
┌ VOICE TEST CONSOLE · Taj Zayka · dev assistant ────────────────────── ● LIVE 01:47 ── [■ End call] ┐
│ call 019fd4fa… · webCall   mic ▮▮▮▯▯  agent ▮▯▯▯▯ speaking   vapi ● connected   cable ● connected  │
├──────── CONVERSATION · source: VAPI (client) ──────────┬────── ORDER BOARD · source: SERVER ───────┤
│ 00:06  CUSTOMER  What pizzas do you have?              │ ORDER #42          ◉ CART OPEN · pickup  │
│ 00:13  AGENT     Margherita, pepperoni or BBQ chicken. │ ────────────────────────────────────────  │
│ 01:18  AGENT     Anything else? Garlic knots go great… │ 1 × Margherita Pizza             $14.00   │
│ 01:24  CUSTOMER  That should be.                       │     + Extra cheese                 $2.00  │
│ 01:26  AGENT     Great. I'll add garlic knots.   ⚠────┼──▶ (board unchanged: still v1)           │
│        ⚠ claim not backed by a server change (heur.)   │ ────────────────────────────────────────  │
│ 01:40  CUSTOMER  read back my order…            ⋯      │ TOTAL                            $16.00   │
│                                                        │ cart v1 · read-back ✓ v1 @01:43           │
│                                                        │ confirmation: ready to submit (needs v1)  │
├──────── SERVER EVENTS · source: RAILS (authoritative) ────────────────────────────────────────────┤
│ T+     TOOL            ARGUMENTS                         RESULT                        CART   SRV   OBS │
│ 00:13  get_menu        –                                 ✓ 6 categories · 20 items     –      9ms  0.4s│
│ 01:10  add_to_cart     Margherita ×1 · Extra cheese      ✓ added · total $16.00        v0→v1  41ms 0.6s│
│ 01:43  get_cart        –                                 ✓ read-back v1                v1     8ms  0.3s│
│ 01:47  submit_order    cart_version 1                    ⋯ pending                                     │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

States:
1. **Idle** — "READY", `[● Start call]`, checklist (mic permission, headphones recommended, "run `vapi:check`
   before recording"), empty panels with source labels.
2. **Connecting** — "◌ CONNECTING…" + `call-start-progress` stage; `[Cancel]`.
3. **Active** — as drawn.
4. **Tool in progress** — pending `⋯` row with elapsed counter; after 20 s with no server row: "no server response
   observed".
5. **Server error** — red row `⛔ rejected · readback_required` or `✖ internal_error`; expansion shows "Agent was told:
   '…'"; board shows e.g. `⚠ submit rejected: cart changed since read-back (v2 ≠ v1)`.
6. **Order confirmed** — `✔ CONFIRMED 🔒 v1 · submitted 01:47`; lines locked; later mutation attempts appear as
   `⛔ order_already_submitted`.
7. **Call ended** — summary strip: duration · Vapi cost · ended reason · tools (ok / rejected / error) · unbacked
   claims · duplicates absorbed; transcript replaced by persisted messages (source: VAPI end-of-call report);
   `[Open call log] [New call]`.
8. **Failed / disconnected** — red banner with cause: mic denied, key/assistant rejected by Vapi, `call-start-failed`,
   Cable disconnected ("server panels paused; will resync" — call continues), Vapi `error`. Server panels keep the
   last committed state.

---

## 13. Implementation sequence

Each step is one or a few commits on branch `phase-1-reliability-console`; CI green after every commit. Steps 1–2
preserve behavior (except the documented generic-adapter removal). Behavior-changing steps flip named R-tests.

| Step | Objective | Likely files | Tests | Accepted when | Deps | Hours |
|---|---|---|---|---|---|---|
| 0 | Preserve baseline; plan in repo | `test/fixtures/files/baseline/**`, `test/baseline/*_test.rb`, `lib/tasks/baseline.rake`, `docs/phase1/PLAN.md` | Characterization 23/23 + replay 2/2 green in CI | Evidence committed; `baseline:verify` reproduces against the tag | — | 1.5–2.5 |
| 1 | `ToolInvocation` log (no behavior change) | migration, model, webhook dispatch wrapper | Rows persisted for every tool; R-suite unchanged | All R-tests still assert old behavior and pass | 0 | 3–4 |
| 2 | Remove generic adapter; extract services (no behavior change on the Vapi path) | delete `api/voice/*` + routes + tests; `order_taking.rb`, `call_lifecycle.rb`, `voice/tool_runner.rb` | First commit retires R21/R22 (reason recorded); then R-suite + replay green with no further test edits | Webhook controller holds no business logic | 1 | 3–4 |
| 3 | Error codes + argument schemas | `voice/tool_arguments.rb`, `tool_runner.rb` | Flip R06, R10, R11 | No `e.message` reaches any response | 2 | 3–4 |
| 4 | Order state rules | `order.rb`, `order_taking.rb`, `admin/orders_controller.rb`, migration (`abandoned`) | Flip R02, R03, R16, R17; admin transition tests | Transactional add; idempotent submit; SMS enqueued once | 3 | 3–4 |
| 5 | Cart version + server read-back | migration, `order_taking.rb`, `readback.rb`, `config/vapi/tools.json`, prompt | Flip R01; stale-version, variants A/B; R15 documented | Submit requires the matching read-back version | 4 | 4–6 |
| 6 | Input rules | `order_taking.rb`, `restaurant.rb`, `db/seeds.rb` | Flip R04, R05, R07, R08, R09 | Limits enforced; 24 h works | 5 | 2–3 |
| 7 | Lifecycle + idempotency + resolution | `call_lifecycle.rb`, `tool_runner.rb`, signed console token helper, migration (call_log fields) | Flip R12, R13, R14, R23; concurrent duplicate test | End-of-call stores cost, reason, sanitized messages | 3 | 4–5 |
| 8 | Menu tools | `menu_catalog.rb`, `tools.json`, prompt | Query/byte budget tests; benchmark script | ≤ 3 queries constant; ≤ 1,600 bytes | 5 | 3–4 |
| 9 | SMS guard | `order_confirmation_sms_job.rb` | Flip R18 | Itemized; web calls skipped | 4 | 0.5–1 |
| 10 | Security | webhook controller, `filter_parameter_logging.rb`, `production.rb`, Devise sessions subclass, notes validation | Flip R20 (no default secret); rate limit; notes cap | Brakeman/RuboCop clean | 3 | 1.5–2.5 |
| 11 | Vapi config in repo + dev assistant | `config/vapi/tools.json`, `config/vapi/assistant.md`, `vapi.rake` (`vapi:check`), `docs/voice_agent/vapi_setup.md` | tools.json ↔ handler/schema parity test | **User:** credentials added and dev assistant created by hand; `vapi:check` passes; baseline assistant untouched | 5, 8 | 2–3 |
| 12 | Action Cable + broadcaster | `app/channels/application_cable/connection.rb`, `console_broadcaster.rb`, partials | Broadcast tests; unauthenticated connection rejected; broadcast failure doesn't fail the tool | Row → board → status order | 7 | 3–4 |
| 13 | Console pages (server-rendered) | `layouts/console`, `admin/console/*`, routes | Renders from DB; review mode; **secrets scan** | Panels correct for replayed calls without browser JS | 12 | 5–7 |
| 14 | Web SDK spike + key config | `config/importmap.rb` (or vendored ESM build), console controller data attributes | Page includes only public key + assistant id + signed token | SDK loads in the page; a restricted-key call starts (**verification item**) | 11 | 1.5–2.5 |
| 15 | Voice console controller | `voice_console_controller.js` | Pending-row de-dup + claim marker (small system test with a stubbed SDK) | Start/stop; live transcript; placeholder → server row swap | 13, 14 | 5–7 |
| 16 | Live verification (**user at the mic**, ngrok) | `docs/voice_agent/verification_log.md` | 5–8 scripted live calls; latency stamps captured | Unknowns resolved or recorded; metadata arrival confirmed; no secrets visible | 15 | 3–5 |
| 17 | Docs | README, `tools.md` (→ points to `tools.json`), `vapi_setup.md`, `local_setup.md` | — | Docs match behavior; README claims corrected (transfer, single source of truth, one adapter) | 16 | 1.5–2 |

**Total ≈ 50–75 h.**

---

## 14. Phase 1 acceptance criteria

Done when:
1. `OrderTaking`, `CallLifecycle`, `Voice::ToolRunner`, `MenuCatalog` exist; the webhook controller contains no
   business logic; the generic adapter is removed.
2. Every R01–R23 test has an intentional new assertion, is kept as already-safe, or (R21/R22) is retired with a
   recorded reason; every change maps to a commit naming its R-IDs.
3. Server owns read-back: `readback_text` generated server-side; submit requires a matching `cart_version` read-back.
4. Submitted orders cannot be mutated by voice tools; admin cannot reopen them.
5. Duplicate submit returns the existing confirmation; the SMS job is enqueued exactly once per order.
6. A duplicate toolCallId returns the stored result, including under a simulated concurrent duplicate.
7. No tool response contains exception text or SQL (scan over all Layer 1 responses).
8. Every tool execution persists a `ToolInvocation` (args, result, status, code, cart versions, duration).
9. Layer 2 verbatim, adapted and dangerous-variant replays are green in CI; `baseline:verify` still reproduces the
   original 23/23 + 2/2 against the tag.
10. `get_menu` ≤ 3 queries (constant under a doubled menu) and ≤ 1,600 bytes; before/after benchmark recorded.
11. The console starts/stops a real Vapi web call and shows live partial/final transcripts.
12. Server rows appear live; pending rows resolve to server rows by toolCallId; the order board always equals DB state.
13. The console resyncs after a Cable reconnect and in review mode for an in-progress call.
14. Secrets scan passes (no private key, webhook secret, raw payloads, control/listen/webCall/recording URLs, org id).
15. `vapi:check` passes for the dev assistant; the baseline assistant is unchanged.
16. The webhook rejects missing/wrong secrets and has no default secret outside `test`.
17. Tests, RuboCop, Brakeman, bundler-audit, importmap audit green; CI green.
18. Coverage not below the 65.7% baseline; new service files ≥ 95%.
19. Verification log records the outcome of every Phase 0 UNKNOWN touched in Phase 1.
20. At least one live console call shows a tool-backed order end to end, and the scripted unclear-upsell attempt is
    recorded.

---

## 15. Not building in Phase 1

Second voice provider · payments · multi-restaurant beyond signed-token resolution · generic agent framework ·
Kubernetes · observability platform · analytics · live admin order editing · SPA/JS framework (unless the importmap
spike fails — then ask) · event sourcing · public unrestricted voice endpoint · phone-number dependency · JWT minting ·
Vapi API writes (`vapi:push`) · SMS status tracking · generic REST adapter · HMAC (Phase 4 optional) · recording
redirect · scenario cards · server-side live transcript streaming · LLM judge · in-browser grading · charts/cost
dashboards · web-call transfer · custom VAD · theme toggles · animated replays · tests for untouched admin CRUD.

---

## 16. Risks

- Web SDK packaging (CommonJS + daily-js) under importmap — spike first (Step 14); fallback vendored ESM build;
  last resort ask before adding a bundler.
- `gpt-5-mini` (minimal reasoning) may mishandle the required `cart_version` — instructive error messages, explicit
  tool description; measured in Phase 2.
- Restricted public key is origin-checked only for browsers — bounded by assistant restriction, max duration, spend
  limit (verify), key rotation.
- Metadata arrival path at the webhook — confirm on the first live call.
- Manual dev-assistant setup can drift — `vapi:check` before every live session.
- Echo/mic issues — headphones.
- Live testing cost ≈ $0.06–0.07/min measured; budget ~$10–20.
- Dashboard polish creep — capped at the wireframe.

# Phase 1 execution log

Implementation notes and deviations from `PLAN.md` (revision 2), one section per step. The plan itself is
unchanged.

## Step 0 — baseline preserved

- Frozen evidence: `test/fixtures/files/baseline/` (byte-identical to Phase 0; `SHA256SUMS` fixes it).
- Runnable copies (the ones that evolve): `test/baseline/reliability_characterization_test.rb` (R01–R23) and
  `test/baseline/live_call_replay_test.rb`.
- `bin/rails baseline:verify` = manifest check + the two ORIGINAL test files run against a throwaway worktree of
  tag `portfolio-baseline` in a throwaway database (`ai_receptionist_baseline_verify`): 23 + 2 pass.
  `baseline:manifest` alone (also run from the suite as `FrozenEvidenceTest`) needs no git history, so CI covers it.
- Implementation details not spelled out in the plan:
  - The two frozen Ruby test files are stored as `*_test.rb.frozen` (content unchanged) so `bin/rails test` and
    RuboCop don't load/lint them; `baseline:verify` restores the names inside the worktree.
  - The replay copy resolves its fixtures via `Rails.root` instead of `File.dirname(__FILE__)`.
  - `FROZEN.md` (new) documents the rule; it is not part of the evidence and not in the manifest.

## Step 1 — ToolInvocation (no behavior change)

- Table `tool_invocations` exactly as PLAN §4 (all columns, unique `(call_log_id, tool_call_id)`, `(call_log_id, started_at)`),
  model `ToolInvocation`, `has_many` from `CallLog` (destroy) and `Order` (nullify).
- Recorded from the Vapi webhook's tool dispatch; bookkeeping only (errors while recording are logged and swallowed;
  the model-facing result is untouched).
- Statuses this step can know: `ok`; `error` (exception, `error_class` set); `rejected` for the two non-exception
  refusals that already exist (`unknown_tool`, `cart_empty`). Other codes arrive in Step 3+.
- Deviations / details not in the plan:
  - Redelivered `toolCallId` is **still re-executed** (R14 characterizes that; changing it is Step 7). The unique
    index means no second row: `replay_count` on the original row is bumped instead. Its meaning changes in Step 7
    from "re-executed" to "absorbed".
  - No `call_log` ("no active call", R11) means no row (`call_log_id` is NOT NULL); a tool call without an `id` is
    executed but not recorded.
  - `cart_version_before/after` stay NULL until Step 5; `source` is always `vapi`.
  - Recording is after the business change and outside its transaction (there is no transaction yet); the plan's
    same-transaction recording arrives with `ToolRunner` in Step 7.

## Step 2 — service extraction + generic adapter removal (no behavior change on the Vapi path)

- New: `OrderTaking` (cart, add/update/remove, submit; returns `OrderTaking::Result`), `CallLifecycle` (start,
  transfer, finish), `MenuCatalog` (`full`, the existing get_menu shape; replaces `Restaurant#voice_menu_json`),
  `Voice::ToolRunner` (arguments → dispatch → error containment → timing → `ToolInvocation`). Under `app/services`.
- `Api::Vapi::WebhooksController` now only checks the secret, extracts provider fields and calls the services
 . The ToolInvocation recording added in Step 1 moved into `ToolRunner`.
- Deleted: `Api::Voice::{Base,Calls,CartItems}Controller`, their routes, and their two controller test files
  (nothing consumed them).
- R21/R22 retired in `test/baseline/reliability_characterization_test.rb` (skipped with the reason, kept by name)
  and replaced by a positive test that the adapter's routes/constants are gone. Frozen originals unchanged.
- Deviations / details not in the plan:
  - `OrderTaking` methods take the parsed tool-argument hash (string keys) rather than typed keywords, and raise the
    same exceptions as before for bad input. This keeps exception text and evaluation order identical (R07, R10);
    `Voice::ToolArguments` in Step 3 turns this into typed input.
  - `OrderTaking#cart` (not `read_back`) and `MenuCatalog#full` (not `overview`/`item`): the plan's names belong to
    the new behavior in Steps 5 and 8.
  - `OrderTaking::Result` is introduced now (payload + optional rejection code) because the runner needs to tell a
    refusal from success; it maps to the existing `rejected`/`cart_empty` ToolInvocation status.
  - Docs that still describe `api/voice/*` (README, `docs/voice_agent/{tools,local_setup,vapi_setup}.md`) are left for
    Step 17, as planned.

## Step 3 — Voice::ToolArguments + structured errors

- `Voice::ToolArguments`: per-tool schema (plain hash). Types: whole number (accepts integer, integral float,
  digit string), list of whole numbers, text, enum. Missing/null required → `<field> is required.`; wrong type →
  `<field> must be … (got "…")`; malformed JSON / non-object → `invalid_arguments`. Unknown fields are dropped and
  never forwarded (R19). Services now receive symbol-keyed, typed keywords only.
- Error contract (string of JSON): `{"ok":false,"error":{"code","message"}}`, message is speakable guidance.
  Codes in use: `invalid_arguments`, `unknown_tool`, `no_active_call`, `menu_item_unavailable`, `item_not_in_cart`,
  `cart_empty`, `delivery_address_required`, `internal_error`. Validation failures → status `rejected`; unexpected
  exceptions → status `error` + `error_class` (kept only in `tool_invocations`/logs) and the model gets
  `internal_error`. No exception text, SQL or class name reaches a response (battery test over 16 bad calls).
- Flipped: R06, R10, R11 (+ R07's raw-text half, R23's no-call string). Successful payloads are unchanged, so the
  live-call replay still compares identical results.
- Deviations: the `"ok":true` marker on successes is deferred to Step 5, where get_cart/submit/get_menu payloads
  change anyway and the replay is rewritten (adding it now would break the verbatim-result replay for no gain).
  `delivery_address_required` and `cart_empty` for update/remove with no cart are decided in `OrderTaking` (they
  replace raw exceptions; no other rule was added).
- Timestamp follow-up: `Voice::ToolRunner` tolerates integer/float/numeric-string timestamps and persists the row
  with a NULL timestamp for anything else; replay tests now assert every real tool call has a ToolInvocation with
  the exact Vapi ms timestamp and that no "could not record tool invocation" line was logged.

## Step 4 — order state and business invariants

Scope note: this step follows the review brief's list. That is plan Step 4 (R03, R16, R17, admin transitions)
**plus** the input rules the plan schedules as its Step 6 (R04, R05, R07, R08, R09). The brief also says "no
duplicate-submit/idempotency yet", so plan Step 4's R02 is **not** flipped (see deviations).

- State: `Order::TRANSITIONS` (pending → confirmed/cancelled/abandoned; confirmed → preparing/ready/completed/cancelled;
  preparing → ready/completed/cancelled; ready → completed/cancelled; completed/cancelled/abandoned final; nothing
  returns to pending), enforced by a model validation and by the admin status picker (current + valid next only).
  `Order#cart_open?` = pending. `abandoned` added to the enum (string column, no migration needed).
- `OrderTaking` rules: cart mutations only while pending (`order_already_submitted`); quantity 1–20 per line
  (`quantity_out_of_range`, also on update); more than 30 items in total (`large_order_requires_staff`, add and
  update); modifiers must all belong to the item (`invalid_modifier`, message lists the valid names);
  `restaurant_closed` on add and submit with today's hours. Unknown/foreign/sold-out items were already
  `menu_item_unavailable` (Step 3).
- Hours: `Restaurant#open_now?` understands `"24h"` and `"00:00-24:00"`; seeds now use `00:00-24:00`. Blank or
  unconfigured hours count as closed (existing semantics, now enforced).
- Atomicity (R16): every mutation runs in one transaction that locks the call row and the order row
  (`with_lock` + `order.lock!`), so order creation, call link, item, and total commit together and mutations on a
  call are serialized. Any exception rolls back.
- R17: `CallLifecycle.finish` moves a still-pending order to `abandoned` (items kept).
- Flipped: R03, R04, R05, R07, R08, R09, R16, R17. Not flipped: R02 (deferred by the brief).
- Deviations / details:
  - `submit` on a `confirmed` order still re-confirms as before (R02's old behavior, deliberately untouched); orders
    that are `preparing`/`ready`/final are refused with `order_already_submitted` so a late submit cannot drag an
    order backwards.
  - Test fixtures that assumed "open" now set `ALWAYS_OPEN_HOURS` (`"24h"`); the R-suite setup and the replay
    restaurant changed from the seeded `00:00-23:59` for that reason (the last-minute gap would otherwise make the
    suite time-of-day dependent). Frozen originals are untouched and still pass against the tag.
  - The dev database's restaurant keeps its old `00:00-23:59` hours until reseeded/edited in admin.

## Step 5 — cart version and server-owned read-back

- `orders.cart_version` (default 0), `read_back_version`, `read_back_at`. Every authoritative mutation
  (add / change quantity / remove) bumps `cart_version` by exactly one inside its transaction; refused or failed
  mutations roll back and never advance it; reads never do.
- `get_cart` = `OrderTaking#read_back`: returns the cart, `cart_version`, and server-generated `readback_text`
  (`OrderTaking::Readback`: words not digits, modifiers, total). While the cart is open and non-empty it records
  `read_back_version = cart_version`.
- `submit_order` now requires `cart_version`. Missing → `invalid_arguments`; never read back → `readback_required`;
  argument ≠ current or read-back ≠ current → `cart_changed_since_readback`, whose error object carries the
  current `cart_version`. Order of checks: closed → empty → state → delivery address → read-back.
- add/update/remove results carry `confirmation_text` (server-worded, in words) so the model states changes from
  tool results; all object results now carry `"ok": true` (deferred from Step 3, as noted there). `get_menu` is still
  a bare list until Step 6.
- Concurrency: the per-call row lock from Step 4 (call + order rows) serializes mutations, read-backs and submits,
  so a stale submit racing an add either wins before the add (and the add is refused as already submitted) or loses
  to it (and is refused as stale). Tested with real threads on committed data (`order_taking_concurrency_test.rb`).
  No additional locking or event machinery.
- Files from the plan's Step 5 table, done now: `config/vapi/tools.json` (what gets pasted into Vapi; parity test
  against `ToolArguments`) and prompt rules in `docs/voice_agent/system_prompt.md`. The dev assistant, `vapi:check`
  and all Vapi configuration remain Step 11.
- Flipped: R01 (R15 stays as characterized: both parallel adds execute, the read-back shows quantity 2).
- Replay (plan Layer 2): `live_call_replay_test.rb` call #7 "identical results" is replaced by (a) verbatim replay:
  recorded results still covered, submit refused for the missing `cart_version`, cart abandoned; (b) adapted replay
  (version injected from get_cart): the original confirmed $16 order, with ToolInvocation/timestamp assertions;
  (c) variants: no get_cart → `readback_required`; add after read-back → `cart_changed_since_readback`. Call #6 is
  unchanged. The frozen originals still pass verbatim against the tag (`baseline:verify`).
- Deviations: see "ok:true" above; the brief's replay requirement is met by the plan's Layer 2 restructuring rather
  than literal unchanged assertions, because the contract changed by design.

## Step 6 — menu optimization (plan Step 8's menu work)

Numbering note: the review brief's "Step 6" is the menu work the plan schedules as Step 8 (the plan's own Step 6
input rules were delivered in Step 4 above). Only the menu code/tool contract is done here; nothing from Steps 7+.

Measured on the real 6-category / 20-item Taj Zayka menu (dev database; `bin/rails runner script/menu_benchmark.rb`,
the same file run against a worktree of `portfolio-baseline` for "before", median of 50):

| | queries | bytes | median |
|---|---|---|---|
| get_menu before (`Restaurant#voice_menu_json`) | 51 | 4,554 | 17.7 ms |
| get_menu after (`MenuCatalog#overview`) | 3 | 1,526 (1,551 with the `ok` envelope) | 0.9 ms |
| get_menu_item (new) | 3 | 310 | 1.0 ms |

- `MenuCatalog#overview`: categories → items `{id, name, price, customizable}`; 3 queries regardless of menu size
  (tested at 20 and 40 items). Categories with nothing orderable are omitted. `MenuCatalog#item(id)`: description,
  modifiers (id, name, price), available pairings; `nil` for unknown / sold-out / other-restaurant items.
- `get_menu_item` tool (`menu_item_id`) added to `Voice::ToolArguments`, the runner, `config/vapi/tools.json` (parity
  test covers it) and the prompt. Unknown item → `menu_item_unavailable`.
- Pairings: dropped from get_menu, so `add_to_cart` results now carry `suggest_with` (available pairings) and
  `get_menu_item` carries them too.
- `get_menu` result is now `{"ok":true,"categories":[...]}`. Preloading replaced the per-item `.available` scope calls.
- Tests: `menu_catalog_test.rb` (contents/exclusions/order), `menu_performance_test.rb` (query counts, doubling,
  byte budget, runner envelope), replay test proving `get_menu` + `get_menu_item` together still carry everything the
  recorded real-call `get_menu` carried (ids, names, prices, descriptions, modifiers, pairings).
- Also in this commit: a call with no/invalid tool name is now audited with tool_name `(none)` (the Step 3 battery
  test showed its ToolInvocation row was being silently dropped by the presence validation - same class of problem as
  the Step 2 timestamp bug). No caching was added.

## Step 7 — transactional ToolInvocation + idempotency (R14)

- **Transaction boundary** (`Voice::ToolRunner#call`): `BEGIN` → lock the call row (`call_logs`, then the order row
  as every mutation already did - lock order unchanged) → look up `(call_log_id, tool_call_id)` → if found, replay;
  otherwise run the tool inside a savepoint, insert the `ToolInvocation` (result, status, error code/class, cart
  versions, timing, Vapi timestamp) → `COMMIT`. Business change and audit row commit or roll back together. An
  unexpected tool exception rolls back only its savepoint, and the `error` row (with `internal_error`) commits.
- **Idempotency:** a redelivery finds the committed row, does `replay_count += 1`, and returns the stored `result`
  string. Nothing else runs: no mutation, no version bump, no read-back refresh, no SMS, no new order. Concurrent
  deliveries queue on the call-row lock, so the loser always sees the winner's committed row; the unique index is
  the backstop (a `RecordNotUnique` retries once and then replays). `replay_count` now means "duplicate deliveries
  detected and answered from the stored result", never executions.
- **Cart versions:** `cart_version_before/after` are recorded on every row (0 while there is no order). Reads and
  refused/failed calls record before == after.
- **Audit failure:** if the audit insert itself fails (not the business), the transaction rolls back - the business
  change with it - and the request is served once, unrecorded and non-idempotent (logged). The model response is
  unchanged, and nothing is ever applied twice. Calls with no `toolCallId` take the same unrecorded path.
- **SMS:** `config.active_job.enqueue_after_transaction_commit = true`, so the confirmation job is enqueued only when
  the tool call's transaction commits (it was `false`, i.e. enqueued inside the transaction).
- `ToolInvocation.record!` is now insert-only; the old "bump replay_count inside record!" is gone.
- Flipped: R14. Step 6 replay structure and the timestamp / "no could-not-record" assertions unchanged and green.
- Deviations: none from the plan. Two details: every tool call on a call now serializes on the call row lock (the
  plan's idempotency design needs this or the unique-index wait); the audit-failure path above is a deliberate
  reading of "an audit failure cannot alter the model response" given atomicity.

## Step 8 — call lifecycle: locking, transfer precedence, idempotent events (R12, R13)

Scope: the lifecycle items from the review brief. Not done here (not requested): console session key / signed
console token (R23), end-of-call cost / ended_reason / messages columns - those remain in the plan for later.

- **Locking:** `CallLifecycle.transfer` and `.finish` now run under `call_log.with_lock`; `finish` then locks the
  order (`call_logs` -> `orders`, never the reverse; a test records every `FOR UPDATE` statement and asserts the
  order). A tool call and a lifecycle event can no longer decide about the same call/order at once.
- **Status rules** (documented atop `CallLifecycle`): transfer -> `transferred` from any status (even after the call
  ended; transferred > completed > abandoned; second transfer is a no-op, first reason kept); finish -> `transferred`
  if transferred, else `completed` if an order was submitted (`Order#submitted?`: past pending and not abandoned, so a
  kitchen-advanced order still counts), else `abandoned`; an open cart becomes `abandoned` (items kept), a submitted
  order is never touched; a repeated finish is a no-op (first end-of-call report wins).
- **Transfer facts:** `call_logs.transferred_at` / `transfer_reason` (new migration). The `[Transferred to human]`
  transcript line is gone, so the end-of-call transcript cannot overwrite it; the admin call page shows the reason.
- **Ended calls:** cart tools (`add`, `update`, `remove`, `get_cart`, `submit`) on a call with `ended_at` answer
  `no_active_call`, so a late or racing tool can never create an order nobody will finish. Replays of earlier tool calls
  still return their stored result (the replay lookup runs first). `transfer_to_human` is still honoured after the
  call ended, by precedence. (No new error code: `no_active_call` already exists in the plan.)
- **Identifiers:** `start` is keyed by the call id (unique index; create-or-find, duplicates and races are absorbed,
  HTTP 200 - R13 flipped, previously 422 on the race); `finish` by the call id (one report per call, `ended_at` is the
  guard); transfer by its toolCallId (Step 7). No event is keyed by timestamp or payload hash.
- Also: customer find-or-create in `start` survives a concurrent create (`RecordNotUnique`/uniqueness `RecordInvalid`).
- `MenuPerformanceTest` now resets primary-key sequences after its explicit-id inserts (it was order-dependent).
- Flipped: R12, R13. Step 7 tests unchanged and green.

## Step 9 — SMS guard

- **Detection:** `Customer#sms_capable?` = phone number matches E.164 (`+` country code, 7–15 digits). Browser/web calls
  carry a synthetic `unknown-<call id>` placeholder, which never matches.
- **Submit:** the `pending -> confirmed` transition decides. Real number -> `OrderConfirmationSmsJob.enqueue_after_commit`
  and result `confirmation_sms: "queued"`; web/synthetic caller -> nothing is enqueued, the skip is logged
  (`[SMS] skipped confirmation for order <id>: caller has no SMS-capable number`, no number) and the result says
  `confirmation_sms: "skipped_web_call"`. The value lives in the tool result and therefore in
  `tool_invocations.result`, which is what a console can show; no new table or column. A submit on an already
  submitted order is idempotent (see below) and says `already_handled`.
- **Job:** re-checks `sms_capable?` (defence in depth) and sends an itemized body
  (`1x Margherita Pizza (Extra cheese), ...; Total: $21.50`).
- **Post-commit, contained:** `enqueue_after_commit` uses `ActiveRecord.after_all_transactions_commit` (the global
  `enqueue_after_transaction_commit = true` from Step 7 is unchanged) and rescues its own failures, logging only the
  error class and order id. An enqueue failure therefore never rolls back or alters the confirmed order or the model's
  answer. (Probe: with a raising adapter and plain `perform_later`, the exception escaped inside the transaction and
  rolled the order back, so containment is explicit.) A crash between COMMIT and the enqueue still loses the SMS: known
  limitation, no outbox by design.
- **R02 flipped here (deviation from the brief's Step 4 deferral, required for "duplicate submit: no second SMS"):**
  `submit_order` on a confirmed / preparing / ready / completed order returns the existing summary with
  `already_submitted: true`, writes nothing, queues nothing, and skips the closed-hours/version checks. Cancelled and
  abandoned orders still refuse with `order_already_submitted`.
- **Fields owned by other steps, untouched:** cost, ended reason, sanitized messages, console session key and R23 are
  in the plan's Step 7 row (lifecycle + resolution), not Step 9; they remain open. The console token part of R23 also
  depends on the console steps (12–14).
- Flipped: R02, R18. Tests that assert SMS counts now use callers with a real number; web-call variants assert zero.
  Replay call #7 (a browser call) now expects the order confirmed with the SMS skipped.
- Prompt and `tools.json` tell the model to promise a text only when `confirmation_sms` is `queued`.

## Step 10 — security and sensitive-data hygiene

Plan items done (PLAN §11 and the Step 10 row): no default webhook secret, payload logging, parameter filtering, TLS
in production, sign-in rate limit, notes cap, secret scan. Not done here (assigned to console steps or other
steps): console session key / signed console token, browser Vapi key, Web SDK and Action Cable authorization,
R23 / restaurant resolution (`Restaurant.count == 1` fallback is untouched), HMAC, the rendered-page secrets scan
(Step 13, it needs pages).

- **Webhook secret:** `ENV["VAPI_SERVER_SECRET"]` or credentials `vapi.server_secret`; no default in any
  environment (tests set an explicit value). Unset or shorter than 16 characters -> every request is refused with 401
  and an error is logged (fail closed; chosen over a boot-time raise so `assets:precompile` and the Docker build keep
  working). The old default string is never accepted. Constant-time compare unchanged.
- **Logging:** the full-payload `logger.info` is removed in every environment (stricter than the plan, which kept it
  for development). Now logged: `[Vapi] event type=<type> call=<id>` and, for tool calls,
  `[Vapi] tool-calls call=<id> <tool>#<toolCallId>=<ok|error code>`; values are cut to a short single-line token
  (`\w.:-`, 64 chars). `filter_parameters` gained `message, artifact, transcript, customer, phoneNumber, monitor,
  transport`, so Rails' own "Parameters:" line shows `"message" => "[FILTERED]"`.
- **Exception hygiene:** tool-runner failures are logged as `<class> at <first app frame>`; exception messages are never
  logged (they can carry SQL values or provider text) or returned. `ToolInvocation.error_class` keeps the class.
  Nothing new is stored in ToolInvocation.
- **Also:** `assume_ssl` + `force_ssl` in production (`/up` excluded); `Users::SessionsController` with
  `rate_limit` 10 sign-ins / 3 min (test cache store is now `:memory_store` so the limit is testable); notes <= 300
  characters (argument schema, `OrderItem`/`Order` validations, `tools.json`).
- **Secret scan:** tracked files were checked for the old default, Twilio SIDs, private key blocks, sk-/GitHub/AWS
  key shapes, and hard-coded secret assignments; `.kamal/secrets` holds only an ENV reference; `config/master.key` and
  `.env*` are untracked. Only the old default string remained (README, two setup docs, the controller), now removed.
  `test/security/secrets_scan_test.rb` keeps this as a check (history files excluded).
- Docs: README env table, `local_setup.md` and `vapi_setup.md` now say the secret is required, how to generate it
  (`openssl rand -hex 32`) and that it is never committed. Other stale `api/voice` text stays for Step 17.
- Flipped: R20. Known gap: development logs at debug level still show SQL with customer phone values (INSERT
  statements) - framework behaviour, dev only.

## Step 11 — Vapi configuration parity (repo side done; live alignment NOT done)

**Blocked on access, recorded honestly.** This session has no Vapi credential: none in the environment or in Rails
credentials (`vapi.*` does not exist), and the built-in browser is not signed in to the Vapi dashboard (it lands on the
sign-up page). Per instructions I did not ask for credentials and did not sign in or create an account, so the
development assistant could **not** be inspected, created or changed, and `bin/rails vapi:check` could not run
against a live assistant. No Vapi write of any kind was made; the baseline assistant `8f2053ae…` and all other
assistants are untouched. The plan's own design is that the dev assistant is created by hand from `config/vapi/*`
(`assistant.md` is the checklist); `vapi:check` is what verifies it afterwards.

**Known differences (repo vs the last captured assistant, not live).** The only assistant configuration available is
the baseline v4 assistant as Vapi sent it with call #7 (frozen fixture). Running `VapiConfig::DriftCheck` on it
reports, and these are exactly what a hand-built dev assistant must fix:
- tools: `get_menu_item` missing; `submit_order` lacks `cart_version` (and its `required`); `notes` has no `maxLength` 300
  on `add_to_cart`/`submit_order`; descriptions of `get_menu`, `add_to_cart`, `get_cart`, `submit_order` differ
  from `config/vapi/tools.json`;
- prompt: differs from `system_prompt.md` (38 repo lines absent, 27 extra);
- `serverMessages` is unset (defaults to everything); must be exactly `status-update`, `tool-calls`, `end-of-call-report`;
- webhook secret: sent as header `X-Vapi-Secret`; its value is redacted in the capture, so match/mismatch is unverifiable
  from here (and the Step 10 rules now require a 16+ character `VAPI_SERVER_SECRET`);
- already equal: model `openai/gpt-5-mini` (reasoning `minimal`), voice `vapi/Elliot`, STT `soniox stt-rt-v5`, server URL
  path `/api/vapi/webhooks`, `maxDurationSeconds` 300.

**Delivered (repository only, no Vapi writes):**
- `config/vapi/assistant.json` (machine-readable settings) and `config/vapi/assistant.md` (hand checklist, what the API
  cannot show: public-key restrictions, spend limit). `tools.json` and `system_prompt.md` remain the other two sources.
- `bin/rails vapi:check`: read-only (`VapiConfig::Client` has GET of `/assistant/:id` and `/tool/:id` only). Needs
  `VAPI_PRIVATE_KEY` + `VAPI_DEV_ASSISTANT_ID` (env or credentials); refuses the baseline id; output lists tools,
  prompt, model/voice/STT, max duration, serverMessages, server URL (https, path, optional `VAPI_EXPECTED_HOST`),
  and the webhook secret as match / mismatch / missing / unverifiable - never the value. Exit 1 on drift.
- `VapiConfig::DriftCheck` is pure (no I/O, never sees a credential) and unit-tested with fixtures: missing, unexpected
  and duplicated tools, the zero-tool assistant (call #6), argument add/remove/type/enum/items/required differences,
  description drift, async or per-tool server overrides, prompt drift (whitespace-insensitive), model/voice/STT, the
  300 s limit, serverMessages, backoffPlan, URL/path/https/host, secret verdicts, and the baseline refusal.
- CI parity (`tool_contract_test`): tools.json definitions-only (no URL/header/secret), exactly the server's handlers
  and argument schemas, prompt mentions every tool and the protocol terms (`cart_version`, `readback_text`,
  `confirmation_sms`, ...), `assistant.json` agrees with its checklist, and the webhook route exists.
- Prompt: new "order system is the source of truth" section (you propose, the server decides; `ok:false` means not
  done; state changes only from results; `get_cart` read-back; `cart_version`; `get_menu_item` for details;
  `confirmation_sms` is informational and never claims delivery). `VapiConfig.webhook_secret` is now shared by the
  controller and the checker.
- Not achievable here: the public-key restrictions and the spend limit cannot be read through the API; both are manual
  (documented in `assistant.md`). Temporary-drift exercise against a real assistant: not possible without access;
  covered by the unit tests instead.

## Step 12 (brief numbering) — browser voice console shell, R23, Web SDK

Brief numbering note: steps 12-14 of the current brief are the plan's console work (plan Steps 7-tail, 13-15 here, then
the evaluation layer). Nothing in this entry was tested against Vapi live: no key, no assistant, no call was made.

- **R23 / console token (was open since Step 8):** `ConsoleToken` = `message_verifier(:vapi_console)` token of
  `{restaurant_id, session_key}`, 15 minutes, purpose-bound, verified at the webhook. `CallLifecycle.start` resolves the
  restaurant as: valid token -> dialed number -> sole restaurant only where
  `config.x.vapi.default_restaurant_fallback` is on (development and test; off in production) -> otherwise refused
  (warning log, no CallLog). The token is read from `call.assistantOverrides.metadata.console_token` (real payloads show
  `call.assistantOverrides`; that the SDK's `metadata` override is echoed there is **unverified until a live call**),
  with `call.metadata` and `assistant.metadata` as fallbacks. The session key is stored on `call_logs.console_session_key`.
  R23 flipped. Forged, tampered, expired, wrong-purpose, malformed and unknown-restaurant tokens are all refused.
- **Outcome facts (plan §4):** `call_logs.ended_reason`, `duration_seconds`, `cost_usd`, `assistant_version` from the
  end-of-call report (defensively typed; nothing else from the report is kept).
- **Console:** `/admin/console` (Devise-protected, own dark layout), `POST /admin/console/token` (fresh token per call
  start), `/admin/console/calls/:id` (only the signed-in restaurant's calls). `voice_console_controller.js` starts/stops
  the call, shows status, elapsed time, agent speaking/volume, mute, live partial/final transcript, error states (mic
  denied, key/origin rejected, call failed), a `beforeunload`/Turbo leave warning, and renders with `textContent`
  only. `console/transcript.js` is a pure module (Node-tested). The page receives only the restricted public key and the dev
  assistant id (`VAPI_PUBLIC_KEY`, `VAPI_DEV_ASSISTANT_ID`; credentials `vapi.public_key` / `vapi.dev_assistant_id`);
  when unset it shows what to configure and disables Start; the frozen baseline assistant id is refused.
- **Web SDK packaging spike (plan risk):** jspm's download of `@vapi-ai/web` is unusable under importmap (it imports a
  sibling `./api.js` that is not downloaded). Vendored instead from jsDelivr's `+esm` builds: `vendor/javascript/vapi-web.js`
  (@vapi-ai/web 2.7.1, one edit: its absolute daily-js import now uses the importmap name) and `daily-js.js`
  (@daily-co/daily-js 0.87.0). **Verified in the built-in browser against the local dev app:** both modules resolve through
  the importmap and `new Vapi(<fake key>)` constructs with `start/stop/on/setMuted/isMuted`; the SDK's class is
  `sdk.default.default` (CommonJS wrapper), which the controller unwraps. The page rendering and transcript row handling
  were exercised there with *synthetic* messages fed to the controller, including an HTML-looking string that stayed text.
  No call was started and no microphone permission was requested.
- Not in this step (next): the order board, server event stream, Action Cable, correlation and the unbacked-claim marker.

## Step 13 (brief numbering) — server-authoritative dashboard

What the console now shows, all rendered from committed database state (never from transcript text or a raw Vapi payload):
- **Server call** strip (status, server start time, tool tallies ✓/⛔/✖, duplicates absorbed, ended reason/duration/cost),
  **Order board** (status, lines, modifiers, total, cart version, read-back state `not delivered` / `delivered for vN at …` /
  `STALE: cart vN, read-back vM`, confirmation state, SMS outcome from the submit's stored result) and **Server events**
  (one row per ToolInvocation: T+ from server timestamps, tool, sanitized arguments, result summary, status, `vA → vB`,
  server ms, replay count, "what the agent was told"; plus lifecycle rows: started, transferred, ended).
- **Delivery:** `ConsoleBroadcaster` (only broadcaster; after commit via `ActiveRecord.after_all_transactions_commit`;
  failures logged by class and never reach the tool response). Tool call -> event row, board, status (fixed order);
  replay -> the row is replaced with "↺ replayed ×N" (nothing appended); lifecycle -> row, board, status. Board/status are
  full snapshots, event rows have stable ids (`tool_call_<id>`), so a missed or repeated message cannot leave the page wrong.
- **Attach:** the console page holds a signed bootstrap stream (`console_session:<key>`); when a call with its session key
  starts, the server updates `#console-call` with the call's own stream plus two `turbo-frame`s that load
  `/admin/console/calls/:id/state` (status + board; events) from the database.
- **Reconnect / backfill:** those frames ARE the persisted state. `console-sync` reloads every `turbo-frame[src]` when a cable
  stream connects or reconnects, and `/admin/console/calls/:id` (observe/review) renders the same frames. A test proves the
  rebuilt row ids equal what the live stream delivered, and that events missed while disconnected appear after a reload.
- **Client observation vs server authority:** when Vapi announces a tool call the browser inserts a `⋯ client observed ·
  awaiting the server's record` placeholder with the same DOM id the server row will have; the server's row replaces it and
  the obs column shows observed latency (browser receipt clock only). If no server row arrives in 20 s the row says
  `⚠ no server record of this tool call was observed`.
- **Unbacked-claim marker:** `ClaimDetector` (one list of patterns, shared by Ruby and the browser) + `ClaimTracker`: an
  assistant line matching a claim ("I'll add garlic knots") with no server event that changed `cart_version` within
  -2 s / +8 s (browser receipt clock) gets `⚠ claim not reflected in the server order (heuristic)`. Display only; it never
  touches order state.
- **Authorization:** Action Cable connections need a Devise session. `ConsoleChannel` (Turbo's own streams channel plus a
  check) accepts a signed stream only if it is `console_session:*` or a call stream of the signed-in user's restaurant;
  everything else is refused (deny by default), so a call id - or even a validly signed name for another restaurant's
  call - is not enough. Deviation from the plan's "no custom channels": this subclass is the documented Turbo extension point
  and exists solely for that authorization.
- **What is never broadcast:** delivery addresses (shown as "address on file" / "address given"), free-text notes (shown as
  a character count), phone numbers, secrets, provider URLs, raw payloads, exception text (rows show only the error code and
  the guidance the agent was given). Tests assert each.
- **Verified in the built-in browser** against a *local* development server on a scratch database (dropped afterwards),
  driving the real webhook with a locally generated signed token and explicit dummy secrets/keys: the page attached to the
  call over Action Cable, events, board, status and the STALE read-back updated live, a replayed `get_cart` showed
  "↺ replayed ×1", a rejected add showed `⛔ rejected · invalid_modifier` and left the cart at v1, a client-observed
  placeholder was replaced by its server row (observed 11.0 s) and an unmatched one was flagged, and the garlic-knots claim was
  flagged; a reload rebuilt the page from the database. The browser-side transcript and tool-call announcements in that
  exercise were **synthetic** (fed to the controller); no Vapi call, key or assistant was involved.
- Polish found in that run: the events table scrolls horizontally instead of squeezing on narrow screens; panels have spacing.

## Step 14 (brief numbering) — reliability evaluation and evidence

Live model / Vapi execution was not possible (no credentials). The harness is built on recordings and scripted variations and
says so in every output.

- `Evaluation` (`app/services/evaluation/`): `World` (the real Taj Zayka menu from the frozen snapshot, created per
  scenario), `Scenarios` (14 scripted scenarios; every conversation prefix up to the claim is verbatim from call #7),
  `Runner` (runs each through `Voice::ToolRunner` inside a rolled-back transaction; separates claims / tool calls received /
  cart mutations / authoritative order), `Evidence` (writes the JSON files).
- Two safety invariants are checked in every scenario and held in all 14: every order line came from an accepted
  `add_to_cart`; an order is confirmed only at the read-back version.
- Result of the set (counts, not rates): 11 assistant claims; 6 not reflected in the server order (the recorded garlic knots
  claim is one: server order stays $16 Margherita-only, confirmed, while the agent claimed knots); 54 tool calls received,
  22 mutated the cart, 7 refused (rejected modifier, missing/stale read-back, closed order); 2 duplicate deliveries absorbed;
  a late duplicate `get_cart` left `read_back_version` at 1 and the later submit of v2 was refused.
- Honest limits shown by the scenarios themselves: the console's window heuristic has a false positive
  (`claim_tool_arrives_late`: add accepted 12.5 s after the claim) and a false negative (`two_items_claimed_one_added`: a cart
  change backs the claim in time but the fries are missing). The item-aware state comparison (Ruby only, used by this
  harness; the console page and the review page do not show it) catches the second; neither is authoritative.
- Evidence files: `docs/phase1/evidence/` (see its README): probe, latency, idempotency/cart versions, test counts, manifest.
  `evidence_test.rb` keeps them from going stale and keeps live items marked PENDING.
- PENDING (not done, not faked): a real browser call through the console; `vapi:check` against the live dev assistant; the
  Layer 3a live-model sample; browser-observed latency on a live call; metadata arrival of the console token at the webhook.

## Step 11 follow-up — the development assistant exists and `vapi:check` is clean

With the owner's explicit instruction and the Vapi private key they saved in Rails credentials (never printed), the
development assistant was created with one `POST /assistant` (a one-off script, not part of the repository; there is
still no Vapi write automation):
- Read first: `GET /assistant` showed two assistants, the frozen baseline `8f2053ae…` and a default "Riley" template with
  no tools; there was no dev assistant. Nothing existing was modified or deleted.
- Created "Taj Zayka Receptionist (dev)" (`f858bbe9…`) from the repository files: model, voice and transcriber from
  `config/vapi/assistant.json`, the system prompt, the 8 tools from `config/vapi/tools.json` (inline, synchronous, no
  per-tool server), `maxDurationSeconds` 300, `serverMessages` exactly `status-update` / `tool-calls` /
  `end-of-call-report`, server URL `https://salaried-earplugs-appendix.ngrok-free.dev/api/vapi/webhooks` (the owner's static
  ngrok host, taken from their development log) with the `X-Vapi-Secret` header set from `vapi.server_secret`.
- The new id was written to credentials `vapi.dev_assistant_id` (it held placeholder text).
- `bin/rails vapi:check` (with `VAPI_EXPECTED_HOST` pinned): tools, prompt, events, limits and webhook match the repository;
  webhook secret: configured, matches. This resolves an open question: the Vapi API returns the secret header value, so the
  secret is verifiable, not just "unverifiable".
- Still manual / unverified: the public key's restrictions (assistant, origins, no transient assistants) and any spend limit
  are not readable through the API; ngrok was not running, so no request has reached Rails yet; no call has been made.

## Preflight for the first live call (nothing here is a live-call result)

Verified against the live Vapi API (read-only) and locally; **no call was made and Start was not pressed**.
- Credentials: `config/credentials.yml.enc` holds top-level `secret_key_base` and `vapi` with exactly `private_key`,
  `public_key`, `dev_assistant_id`, `server_secret` (all present, values never printed; no env overrides set; public, private
  and secret are three distinct values; the id is a UUID and not the baseline's). The file is modified in the working tree and
  intentionally left uncommitted: it holds the owner's keys (encrypted with the untracked `config/master.key`).
- Dev assistant `f858bbe9…` "Taj Zayka Receptionist (dev)": 8 inline tools (names match the repo, none async, no per-tool
  server), system prompt equal to `system_prompt.md`, `openai/gpt-5-mini` reasoning `minimal`, voice `vapi/Elliot`, transcriber
  `soniox stt-rt-v5` `en`, `maxDurationSeconds` 300, `serverMessages` exactly `status-update`/`tool-calls`/`end-of-call-report`,
  webhook `https://salaried-earplugs-appendix.ngrok-free.dev/api/vapi/webhooks`, secret header present and equal to Rails'.
  `bin/rails vapi:check` (host pinned): OK. Baseline `8f2053ae…` and "Riley" `updatedAt` unchanged since before Step 11.
- Public key restrictions / spend limit: **not inspectable**. The published API spec (71 paths) has no key or org endpoint;
  `GET /api-key` and `/public-key` return 404 and `/org` returns 401 with the private key (dashboard-session auth). Left as a
  manual dashboard check, spelled out in `docs/voice_agent/first_live_call.md`.
- Networking: ngrok 3.39.11 installed; static host still accepted by ngrok and mapped to `localhost:3000`. Started `bin/dev`
  (port 3000 was free) and the tunnel. Synthetic routing probes only: `/up` via the tunnel 200; `POST /api/vapi/webhooks`
  with no secret and with a wrong secret 401; `GET` on the webhook path 404; `/admin/console` unauthenticated 302 to sign-in;
  no rows were created (call_logs 7 before and after, tool_invocations 0).
- Console (browser, `http://localhost:3000`, seeded admin): Start enabled, no setup warning, Action Cable `● connected`,
  assistant id on the page is the dev one, the public key is present once (attribute only), the SDK loads, the token endpoint
  issues a token, and the attach endpoint answers 202 for an unknown call. Server-side crawl of the page and all 15 assets:
  the private key and webhook secret appear nowhere; the public key appears only in the page attribute, not in any script.
- Logs: no key or secret occurrences in `development.log`, `test.log` or the ngrok log; no `[Vapi] event` payload lines.
- Repo fixes made during preflight (separate commits): the test suite no longer depends on the developer's real Vapi credentials
  (it broke two tests once the credentials were filled in); the console can attach to its call by the call id the SDK reports if
  the signed token never reaches the webhook; `bin/rails calls:last` (payload-free call summary) and this runbook.
- Known, not changed: the development restaurant's hours are still `00:00-23:59` (seeds now use `00:00-24:00`), so orders are
  refused during 23:59:00-23:59:59 local time.

## After call #8: prompt/tool fixes, dashboard observations, confirmation proposal

- **Prompt and tool descriptions** (repo, then the dev assistant): never add on a question; ask about options before adding and add
  once with them; to change options remove the line and re-add (no duplicate line); read-back and submit are different turns and
  `get_cart` + `submit_order` are never chained; say `readback_text` in one piece; never read instructions aloud. Tests assert each
  rule is present in the prompt and in the relevant tool descriptions.
- **Dev assistant updated** with one `PATCH /assistant/f858bbe9…` sending only `model` (prompt + tools); name, voice, transcriber,
  first message, max duration, server messages and server settings verified unchanged; the baseline and Riley were not touched;
  `vapi:check` with the host pinned: OK.
- **Dashboard observations** (display only, from server facts): the order board notes a menu item on more than one line; an
  accepted add that leaves the same item on two lines says so on its event row; every submit row states how long after the last
  `get_cart` it arrived (amber under 10 s: an aid for the eye, not a rule, nothing is refused); the "call ended" row is placed at
  start + duration instead of when Vapi's report arrived. Checked on the real call #8 data.
- **Not done, by decision:** no minimum-gap rule. The proposal for making customer confirmation a server-enforced state is in
  `docs/phase1/CONFIRMATION_PROPOSAL.md` (not implemented).

## After call #9: shadow turn evidence at submit (instrumentation only)

- **Why:** Vapi's stored records showed that in call #9 the read-back and `submit_order` came from one model completion and the
  caller's "yes" began 104 ms after the submit request; call #8 likewise had no caller turn before the submit. The "submitted N s
  after the last get_cart" observation was measuring the agent's speech, not the caller's chance to answer. Details and the
  verified payload structure: `docs/voice_agent/verification_log.md` (entries "Correction: call #9…" and "Shadow turn evidence…").
- **What changed:** `Voice::TurnEvidence` derives, per `submit_order`, from the webhook's `artifact` (Vapi's live conversation
  history): history present/missing/malformed, caller turns since the last `get_cart` result (by position, before the submit's own
  entry), caller turns after the submit request (reported, not counted), whether the completion that answered the `get_cart` result
  issued the submit (plus its speech length), millisecond gaps, the last `get_cart` tool-call id and anomaly flags. Stored in
  `tool_invocations.turn_evidence` (jsonb, new column). The controller passes `artifact` through; it is never logged.
- **Console:** the submit row's "submitted N s…" (amber under 10 s) is replaced by "N s since the last get_cart (elapsed time only,
  includes the agent's speech; not evidence the caller answered)", never amber; ◌ lines show the shadow evidence and "confirmation
  gate: shadow only (observed, nothing refused)". `bin/rails calls:last` prints the same lines under the submit.
- **No behaviour change:** `submit_order` runs exactly as before whatever the evidence says (tests compare results, order state and
  SMS decisions with and without history, and with the observer raising). Prompt, tools, model, reasoning effort, SMS, fillers
  and the Vapi assistant are unchanged (`vapi:check` clean).
- **Not done, by decision:** no enforcement, no yes/no classifier, no four-state machine, no `conversation-update` subscription.

## After call #10 (invalid run): unrecorded-fallback fix

- Call #10 failed for infrastructure reasons (stale `bin/dev` after the `turn_evidence` migration), exposing that the "served
  unrecorded" fallback crashed on a call's first cart change after a real rollback (`lock!` on a record still holding the
  rolled-back `order_id`). `Voice::ToolRunner` now re-reads the call row before the fallback and before the unique-conflict retry.
  Regression tests use real top-level transactions. Recorded as an invalid run in `docs/voice_agent/verification_log.md`; the
  runbook now says to restart `bin/dev` after any migration. No prompt, tool, model, reasoning, SMS, filler, turn-evidence or
  enforcement change.

## After Call #4: reasoning effort `minimal` → `low` on the dev assistant

- One variable changed, by owner decision: `reasoningEffort` on the dev assistant `f858bbe9…` (v2 → v3), via one `PATCH` of the
  complete current `model` object (only `reasoningEffort` differed; verified by a before/after comparison of the whole assistant).
  `config/vapi/assistant.json` and `assistant.md` updated to match; `vapi:check` clean. Baseline assistant untouched. No code change.

## After Call #6: reasoning effort restored to `minimal`; first live turn-evidence results

- Vapi's per-call logs showed the `low` trial never reached the model: every OpenAI request in Calls #5 and #6 used
  `reasoning_effort: "minimal"` while the assistant was configured `low`. Restored the dev assistant to `minimal` (v3 → v4; one
  `PATCH` of the complete `model` object, only `reasoningEffort` differed; `vapi:check` clean; baseline untouched) and
  `config/vapi/assistant.json` / `assistant.md` to match. `vapi:check` checks configuration, not the downstream request.
- Turn evidence: 3/3 calls that reached `submit_order` (Calls #1, #2, #6) did so with 0 caller turns after the last `get_cart`
  result; Call #6's second submit (after the caller's yes) was absorbed by idempotency. `speech_chars` is unreliable at submit time
  and is not to be used for enforcement. Details in `docs/voice_agent/verification_log.md`.

## Server-side confirmation gate (turn-taking, enforced)

- **Rule** (`OrderTaking#submit`, after the existing read-back and cart-version checks): an order is submitted only if the
  conversation shows **at least one caller turn after the last `get_cart` result**. Otherwise `submit_order` is refused with
  `customer_confirmation_required` (speakable guidance + the current `cart_version`); nothing is written, no SMS. An already
  submitted order still answers idempotently (`already_submitted`), and the earlier codes (`readback_required`,
  `cart_changed_since_readback`, …) still come first. It is a turn-taking gate, not a "yes" detector.
- **Input:** `Voice::TurnEvidence.caller_turn_after_read_back?` over Vapi's `artifact.messages` in the same tool-calls webhook
  (the parser that was validated in shadow mode; evidence schema 2, `mode: "enforced"`). Missing, malformed or unreadable
  history, no `get_cart` result in it, the submit not found in it, or an exception while reading it → **fails closed**.
  `completion` / `speech_chars` are recorded for explanation only and never decide anything. No transcript text is stored.
- **Wiring:** `Voice::ToolRunner` passes the value to `OrderTaking#submit` on the recorded and the unrecorded (fallback) paths;
  the refusal is a normal rejected `ToolInvocation` with its turn evidence, so idempotency (a redelivered refusal returns the
  stored refusal) and the console stream work unchanged.
- **Harness/replay:** `Evaluation::Runner` now sends each tool call the scenario's own conversation so far, like a live webhook;
  three scenario scripts gained the caller's answer after the read-back so they keep their stated purpose (all 14 existing
  outcomes identical); new scenario `premature_submit_then_answered` (refused, then accepted). The call #7 replay reconstructs
  the webhook history from the call's final conversation-update (the real "Yes." precedes the submit, so it still confirms $16).
- **Tests:** `test/controllers/api/vapi/confirmation_gate_test.rb` (the renamed shadow test), predicate tests on the live
  structures of calls #8, #9 and #13 (`live_submit_webhook_call13_{first,second}.json` added), R24 in the reliability suite.
  Other tests that mean "the caller answered" send such a history (`VapiHistory` in `test/test_helper.rb`); domain-rule tests
  that call `OrderTaking#submit` directly pass `caller_turn_after_read_back: true`.
- **Not changed:** prompt, tools and the live Vapi assistant (the refusal message carries the guidance); no state machine, no
  classifier, no timers, no `conversation-update` subscription. **Not yet verified on a live call.**

## Console: refused submits made obvious

- A submit refused by the confirmation gate reads `confirmation required · submit refused (N caller turns since the last get_cart;
  nothing was submitted, vN kept)` (or `no readable conversation history`), with the ◌ turn evidence and
  `confirmation gate: submit refused (no caller turn after the read-back)` under it; the board's confirmation field says
  `submit refused: waiting for the caller's answer to the read-back (vN)` until a later submit is accepted. Both come from server
  records (the rejected `ToolInvocation` and its turn evidence); no transcript or payload text is shown.
- The same-completion line no longer quotes `speech_chars` (unreliable at submit time). Runbook updated for the next live call.

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

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

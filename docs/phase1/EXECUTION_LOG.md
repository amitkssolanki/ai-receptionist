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

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

# Frozen Phase 0 evidence — never edit

Everything in this directory is the Phase 0 baseline evidence for tag `portfolio-baseline`
(`257a9e71c5a3f6cc5ef45b224732857773b12ef3`), copied byte-for-byte from the Phase 0 scratch directory.
`SHA256SUMS` fixes the content; `bin/rails baseline:verify` checks it and re-runs the two original test files
against a worktree of the tag.

Only difference from the Phase 0 originals: the two Ruby test files carry a `.frozen` suffix
(`*_test.rb.frozen`) so `bin/rails test` and RuboCop don't pick them up. Content is unchanged.

Runnable, evolving copies live in `test/baseline/`. Those are the ones that change in Phase 1.

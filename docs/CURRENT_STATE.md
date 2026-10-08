# Current state

Recorded 2026-10-08 at the repository closeout. This is the reference for "where the project stands"; the dated documents
under `docs/phase1/`, `docs/phase2/` and `docs/voice_agent/` are history and stay as written. No secret values appear here.

## Summary

The AI Restaurant Receptionist is **production-complete and frozen**: Phase 1 (reliability, confirmation gate, live voice
console), Phase 2 (the thesis on camera) and the production deployment are done and merged. It is a portfolio project: one
demo restaurant ("Taj Zayka"), browser voice only, no customers.

## Repository

| | |
|---|---|
| Branch | `main` is the only branch, locally and on GitHub |
| Code baseline | `fab8b2e` (Merge PR #23, solid_cable 4.1.0): the last change to application code or dependencies, CI green |
| On top of it | documentation-only closeout commits; `git log -1 origin/main` is the authoritative final commit |
| Tag | `portfolio-baseline` (`257a9e7`): the frozen Phase 0 baseline that `bin/rails baseline:verify` checks against. Keep it |
| Open PRs | none |
| CI | GitHub Actions `CI` (`scan_ruby`, `scan_js`, `test`, `lint`) green on `main` |
| Stack | Ruby 3.4.7, Rails 8.1.4, PostgreSQL, Hotwire/Tailwind, Solid Queue/Cache/Cable, Vapi (web calls), Kamal 2.12.0 |

Merged history that represents the completed work: PR #17 (Phase 1), #18 (Phase 2), #19 (homepage, `/admin` dashboard,
production preparation), #20 (homepage link-preview image), #21 (dependency updates), #22 and #23 (Dependabot: Rails 8.1.4,
solid_cable 4.1.0; merged at the closeout, see below).

## Production

| | |
|---|---|
| Hostname | https://restaurant-receptionist.railsfanatics.com |
| Deployment | Kamal 2, deployed 2026-10-01 with [`docs/deploy/PRODUCTION.md`](deploy/PRODUCTION.md); last deployed commit `f964ef7` |
| Not deployed | `main` after `f964ef7`: Rails 8.1.3.1 → 8.1.4 and solid_cable 4.0.0 → 4.1.0 (PRs #22, #23) plus documentation. Deploying them is the owner's decision; the runbook's checks apply |
| Infrastructure | a VPS shared with the owner's other Kamal apps and one shared `kamal-proxy` (never rebooted from this repository) |
| Database | a dedicated Postgres 18 accessory, `ai-receptionist-postgres`, used by no other app |
| Vapi | a separate production assistant, "Taj Zayka Receptionist (production)", and a separate production public key restricted to the production origin and that assistant, no transient assistants |
| Mode | browser voice calls from the signed-in console (`/admin/console`); no phone number, no Twilio, no SMS |
| Admin bootstrap | `ADMIN_PASSWORD` was used once for the first admin and then removed from the deployment (runbook step 16) |
| Post-deploy checks | 11 of 11 passed on `f964ef7` (2026-10-01): `/`, `/og.png`, `/up`; anonymous `/admin` and console redirect to sign-in; webhook 401 without the secret; admin sign-in, dashboard, console, sign-out; Solid Queue processes registered, no failed jobs; the other apps on the server unaffected |

Production was not touched at the closeout: no deploy, no Vapi call, no configuration change. The production facts above are
the 2026-10-01 deployment records; they were not re-checked against the live server on 2026-10-08.

### Production smoke test (2026-10-01)

One paid browser call through the production assistant. The model issued `submit_order` before the caller answered the
read-back; Rails refused it with `customer_confirmation_required`; the caller confirmed; Rails accepted the next submit;
production order #1 became CONFIRMED ($14.00). Recorded in
[`docs/voice_agent/verification_log.md`](voice_agent/verification_log.md) ("Production smoke call").

## Tests and checks

| Check | Result on `main` (2026-10-08, local and CI) |
|---|---|
| `bin/rails test` | 473 runs, about 4,070 assertions (the concurrency tests vary slightly run to run), 0 failures, 0 errors, 2 skips (R21/R22, retired with the removed adapter) |
| `bin/rails baseline:verify` | OK: 25 frozen Phase 0 tests pass against `portfolio-baseline` |
| RuboCop | 154 files, no offenses |
| Brakeman | 0 errors, 0 security warnings |
| bundler-audit / importmap audit | no vulnerabilities / no vulnerable packages |
| `bin/rails zeitwerk:check`, production asset precompile | OK |
| Secret scan | `test/security/secrets_scan_test.rb` (part of the suite) passes; GitHub secret scanning and push protection are on, 0 alerts |

## Authentication and security

- Every page except the homepage `/`, sign-in and `/up` needs a signed-in admin (Devise); no sign-up, no emailed password
  reset (`test/security/anonymous_boundary_test.rb`).
- The Vapi webhook requires `X-Vapi-Secret`; there is no default secret and requests are refused without one.
- Only the restricted public key and the assistant id reach a browser, and only on the signed-in console page.
- Production forces TLS (except the health check); request parameter filtering covers webhook bodies and credentials.
- Secrets live outside Git: `.env.kamal` (git-ignored, owner's machine), the owner's password manager / Keychain, Vapi's
  dashboard. The encrypted credentials file is modified locally on the owner's machine and is never committed.
- Dependabot **version updates** run weekly (bundler, GitHub Actions; `.github/dependabot.yml`). Dependabot **security alerts**
  are disabled in the repository settings, so GitHub reports none; `bundler-audit` (CI and local) and `importmap audit` cover
  known advisories and are clean.

## Intentional scope exclusions

These are decisions, not unfinished work:

- No phone calling and no Twilio/SMS in production (the SMS job exists and does nothing without `TWILIO_*`).
- No payments, no multiple restaurants, no call transfer (`transfer_to_human` records the request only), no second voice
  provider.
- Not a real restaurant and no customers; no long-term production, load or uptime claim. "Deployed and smoke-tested", not
  "production-proven" in the sense of operational history.
- The fault-injection assistant was attempted (2 calls) but did not reproduce the failure live; P2-3 is "attempted, not
  demonstrated". The live refusals came from the normal development assistant (call #20) and the production smoke call.
- The agent's conversational reliability is not established (stalls, fillers, announced actions, misheard speech, unrequested
  adds); the server guarantees the order, not the conversation.

## Known limitations carried forward

Recorded, not bugs to fix as part of the closeout: the Call #2 false refusal (the gate depends on the order of Vapi's history;
it fails closed); reasoning effort is not controllable through Vapi (provider fallbacks); the development public key is
unrestricted; the console shows "[object Object]" for a Vapi-ended call; `docs/voice_agent/tools.md`, `vapi_setup.md` and parts
of `local_setup.md` still describe the removed `api/voice` layer (flagged in the README). The Phase 2 report lists them as
Phase 3 candidates, which are candidates only, not an agreed scope.

## Branch policy

- `main` is the only long-lived branch and the only starting point. Do not revive deleted phase branches; their commits are all
  in `main` and their PRs (#17–#21) keep the review history.
- New work: a short-lived branch from the current `origin/main`, merged by pull request with green CI, then deleted (locally
  and on GitHub).
- No history rewriting or force-pushes on `main`; do not delete the `portfolio-baseline` tag.

## Next-phase starting point

See [`docs/NEXT_PHASE_HANDOFF.md`](NEXT_PHASE_HANDOFF.md). No next phase is defined.

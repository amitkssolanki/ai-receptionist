# Production deployment runbook

The AI Restaurant Receptionist at **https://restaurant-receptionist.railsfanatics.com**, deployed with Kamal 2 to the
server MCP Server, Platestead and Keepford (and vrinda and fieldnote) already use. This document holds no secret values: it names every value and
says where it is generated and stored. Configuration: `config/deploy.yml`, `.kamal/secrets`, `config/vapi/production.json`;
`test/deploy/production_config_test.rb` keeps them consistent.

What anyone on the internet can reach once deployed: the homepage `/` (static: it reads no records or configuration), the
sign-in page, sign-out, `/up` (200 or 500, no data), the Vapi webhook (refused without the production `X-Vapi-Secret`) and
static assets. Everything else, including the dashboard at `/admin`, needs a signed-in admin
(`test/security/anonymous_boundary_test.rb`). A browser voice call needs the Vapi public key, which only the signed-in
console page receives.

| | |
|---|---|
| Hostname | `restaurant-receptionist.railsfanatics.com` |
| Server | `91.98.193.40` (shared), SSH user `root` (Kamal's default, as for the other applications) |
| Kamal | 2.12.0 (`Gemfile.lock`), the same version as MCP Server: the shared `kamal-proxy` is not upgraded or rebooted |
| Image | `ghcr.io/amitkssolanki/ai-receptionist` |
| Containers | `ai-receptionist-web-<version>`, `ai-receptionist-postgres` |
| Database | its own Postgres 18 accessory, user `ai_receptionist`, databases `ai_receptionist_production` and `_cache`, `_queue`, `_cable` |
| Vapi | a separate production assistant and a separate, restricted production public key |
| Twilio | not configured: browser calls have no phone number, and the SMS job does nothing without `TWILIO_*` |

## 0. Before anything: capacity of the shared server

This application adds two containers with memory limits: the app (768 MB) and Postgres (256 MB). Read-only check:

```bash
ssh root@91.98.193.40 'free -m; df -h /; docker stats --no-stream --format "{{.Name}} {{.MemUsage}}"'
```

Go ahead only if about 1.1 GB of memory stays available with the other applications running. If not, stop: do not
lower the other applications' limits from this repository.

**Done (2026-10-01, read-only):** 7.7 GB total, 2,698 MB available with every running application (MCP Server,
Platestead, Keepford, plus vrinda and fieldnote); after this application's limits about 1.67 GB stays available. Disk
16 GB free (57% used), load average 0.2 on 4 cores. `kamal-proxy` runs `v0.9.2`, the minimum Kamal 2.12 accepts, so
`kamal deploy` neither aborts nor touches it. No `ai-receptionist` containers or data existed yet.

## 1. DNS

**Done (2026-10-01):** the A record exists and resolves to `91.98.193.40` from the default resolver, 1.1.1.1 and 8.8.8.8,
DNS-only like `mcp-demo`. No AAAA record. Kept below for reference.

Create an **A record** `restaurant-receptionist.railsfanatics.com → 91.98.193.40` at the provider that already serves
`mcp-demo.railsfanatics.com`, with the same settings as that record (if the provider can proxy traffic, leave it
DNS-only like `mcp-demo`, so kamal-proxy can obtain the Let's Encrypt certificate). Before deploying:

```bash
dig +short restaurant-receptionist.railsfanatics.com   # must print 91.98.193.40
```

## 2. The server

Nothing is installed by hand. `kamal accessory boot` and `kamal deploy` add this application's containers next to the
existing ones and register the hostname with the running `kamal-proxy`. Do not run `kamal setup`, `kamal proxy reboot`
or `kamal proxy remove` from this repository: the proxy is shared. Postgres data lives on the host under the SSH
user's home in `ai-receptionist-postgres/data`; no Postgres port is published on the host.

## 3. Registry authentication

`ghcr.io`, user `amitkssolanki`, password `KAMAL_REGISTRY_PASSWORD`: a GitHub token with `write:packages` (the same
kind of token the other applications use). The image package is created on the first push.

## 4. Postgres provisioning

No manual database work. `kamal accessory boot postgres` starts `postgres:18` with `POSTGRES_USER=ai_receptionist`,
`POSTGRES_DB=ai_receptionist_production` and `POSTGRES_PASSWORD`. On its first start the app container runs
`bin/rails db:prepare` (`bin/docker-entrypoint`), which loads `db/schema.rb` into the primary database, creates
`ai_receptionist_production_cache`, `_queue` and `_cable` from their schema files, and runs `db/seeds.rb` (the demo
restaurant, its menu and the one-time admin bootstrap). Later deploys run pending migrations only.

Manual backup before risky changes (writes to the deploying machine). Use plain `ssh`: without `--raw`, `kamal
accessory exec` adds its own lines to the output and would corrupt the dump.

```bash
ssh root@91.98.193.40 'docker exec ai-receptionist-postgres pg_dumpall -U ai_receptionist' > ai-receptionist-$(date +%F).sql
# restore (only into this application's database server):
ssh root@91.98.193.40 'docker exec -i ai-receptionist-postgres psql -U ai_receptionist -d postgres' < ai-receptionist-YYYY-MM-DD.sql
```

## 5. Environment variables

Clear values, committed in `config/deploy.yml`:

| Name | Value |
|---|---|
| `RAILS_HOST` | `restaurant-receptionist.railsfanatics.com` (Host restriction, URLs) |
| `RAILS_LOG_LEVEL` | `info` |
| `DB_HOST` | `ai-receptionist-postgres` |
| `SOLID_QUEUE_IN_PUMA` | `true` |

`RAILS_MAX_THREADS` is deliberately unset: Puma runs 3 threads and each database pool holds 5, which Solid Queue needs
(its 3 worker threads + 2). Setting it to 3 would stop Solid Queue from starting.

Secrets (names in `config/deploy.yml`, values only in `.env.kamal`):

| Name | What it is | How to produce it |
|---|---|---|
| `KAMAL_REGISTRY_PASSWORD` | ghcr.io token (registry only, not in the container) | GitHub token with `write:packages` |
| `SECRET_KEY_BASE` | Rails session and signing key, new for production | `bin/rails secret` |
| `POSTGRES_PASSWORD` | the accessory's password; `.kamal/secrets` also passes it to Rails as `AI_RECEPTIONIST_DATABASE_PASSWORD` | `openssl rand -hex 24` |
| `VAPI_SERVER_SECRET` | webhook secret, new for production, never the development one | `openssl rand -hex 32` |
| `VAPI_PUBLIC_KEY` | the new production browser key (step 10) | Vapi dashboard |
| `VAPI_ASSISTANT_ID` | the production assistant's id (step 8) | Vapi dashboard |
| `ADMIN_EMAIL` | the first admin's email | yours |
| `ADMIN_PASSWORD` | the first admin's password, 16+ characters, one-time | password manager |

Not set in production, on purpose: `RAILS_MASTER_KEY` (production reads nothing from the encrypted credentials),
`VAPI_PRIVATE_KEY`, `VAPI_DEV_ASSISTANT_ID`, `VAPI_FAULT_INJECTION_ASSISTANT_ID` (ignored in production anyway),
`DATABASE_URL` and `TWILIO_*`.

## 6. Kamal secrets: `.env.kamal`

Create `.env.kamal` in the repository root on the deploying machine. It is git-ignored and docker-ignored; never commit
it, paste it into chat or print it.

```bash
touch .env.kamal && chmod 600 .env.kamal
# then add one line per secret from the table above: NAME=value
awk -F= '{ print $1, length($2) }' .env.kamal   # names and lengths only: all 8 present and non-empty
bin/rails test test/deploy                       # the committed configuration is consistent
```

`.kamal/secrets` (committed) reads each value with `grep '^NAME=' .env.kamal`. It never contains a value.

## 7. One-time admin bootstrap

On the first boot `db/seeds.rb` creates exactly one admin from `ADMIN_EMAIL` and `ADMIN_PASSWORD`, attached to the
demo restaurant. It refuses a password under 16 characters (the boot fails, nothing is created). Once any user exists,
the seeds ignore both variables: they cannot create, recreate, reset or change an account. There is no sign-up and no
emailed password reset. To change a password later:

```bash
kamal console   # then: User.find_by!(email: "...").update!(password: "...")  (typed, not stored anywhere)
```

## 8. Production Vapi assistant (dashboard, by hand)

The repository describes the assistant; nothing in it calls Vapi to create one. Do not edit the development assistant
or the frozen baseline assistant, and never use the fault-injection assistant in production.

1. Vapi dashboard → Assistants → the development assistant ("Taj Zayka Receptionist (dev)") → **Duplicate**.
2. Rename the copy **"Taj Zayka Receptionist (production)"** (`config/vapi/production.json`).
3. Check every setting against `config/vapi/assistant.json` and `config/vapi/assistant.md`: model, voice, transcriber,
   first message, `maxDurationSeconds` 300, server messages `status-update`, `tool-calls`, `end-of-call-report`, no
   backoff plan; the 8 tools exactly as `config/vapi/tools.json`, synchronous, without their own server URL; the system
   prompt from `docs/voice_agent/system_prompt.md`.
4. Set the server URL and secret (step 9). The duplicate still points at the development server: replace both.
5. Copy the new assistant's id into `.env.kamal` as `VAPI_ASSISTANT_ID`.

## 9. Production webhook

On the production assistant:

- **Server URL:** `https://restaurant-receptionist.railsfanatics.com/api/vapi/webhooks`
- **Custom header** `X-Vapi-Secret` = the production `VAPI_SERVER_SECRET` from `.env.kamal` (copy it from the file
  into the dashboard field; do not echo it).

Read-only verification from the deploying machine (one GET to the Vapi API; it reports match or mismatch, never the
value). It needs the private key you already use for `vapi:check` locally:

```bash
set -a; . ./.env.kamal; set +a
VAPI_EXPECTED_HOST=restaurant-receptionist.railsfanatics.com bin/rails vapi:check
```

Expected: `OK: tools, prompt, events, limits and webhook match the repository`.

## 10. Vapi public-key restriction (dashboard, by hand)

Create a **new** public key for production rather than restricting the development one (that key serves the local
console on localhost):

1. Vapi dashboard → API Keys → Public Keys → create a key named "ai-receptionist production".
2. **Allowed origins:** `https://restaurant-receptionist.railsfanatics.com` only.
3. **Allowed assistants:** the production assistant only.
4. **Transient assistants:** not allowed.
5. Copy it into `.env.kamal` as `VAPI_PUBLIC_KEY`. It is shown to signed-in admins' browsers only; the private key
   and the server secret never reach a browser.

Also set a spending limit for the organization in Vapi billing if one is not set: it bounds the cost of any misuse.

## 10a. Optional: rehearse the production image locally

No credentials or server access needed; every value is a throwaway generated on the spot. This is how the configuration
was verified before the first deploy (2026-10-01): `db:prepare` created the four databases, the seeds bootstrapped the
admin, Solid Queue started inside Puma, and the Host, sign-in, console, fault-injection and webhook checks of steps 12–14
behaved as written.

```bash
docker buildx build --platform linux/amd64 --load -t ai-receptionist:rehearsal .
docker network create ai-receptionist-rehearsal
docker run -d --name ai-receptionist-rehearsal-pg --network ai-receptionist-rehearsal \
  -e POSTGRES_USER=ai_receptionist -e POSTGRES_DB=ai_receptionist_production -e POSTGRES_PASSWORD=rehearsal-only postgres:18
docker run -d --name ai-receptionist-rehearsal-web --network ai-receptionist-rehearsal -p 127.0.0.1:18080:80 \
  -e RAILS_HOST=restaurant-receptionist.railsfanatics.com -e DB_HOST=ai-receptionist-rehearsal-pg -e SOLID_QUEUE_IN_PUMA=true \
  -e SECRET_KEY_BASE=$(openssl rand -hex 64) -e AI_RECEPTIONIST_DATABASE_PASSWORD=rehearsal-only \
  -e VAPI_SERVER_SECRET=$(openssl rand -hex 32) -e VAPI_PUBLIC_KEY=pk-rehearsal -e VAPI_ASSISTANT_ID=00000000-0000-0000-0000-000000000000 \
  -e ADMIN_EMAIL=rehearsal@example.test -e ADMIN_PASSWORD=$(openssl rand -hex 16) ai-receptionist:rehearsal
curl -s -H 'Host: restaurant-receptionist.railsfanatics.com' -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/   # 200
docker logs ai-receptionist-rehearsal-web | grep -E 'Admin user ready|SolidQueue.*Started'
docker rm -f ai-receptionist-rehearsal-web ai-receptionist-rehearsal-pg && docker network rm ai-receptionist-rehearsal
```

## 11. First deployment

From a clean checkout of the commit to deploy (Kamal builds from the committed tree; uncommitted files such as the
local `config/credentials.yml.enc` are not in the image):

```bash
dig +short restaurant-receptionist.railsfanatics.com   # 91.98.193.40
bin/rails test test/deploy                             # configuration consistent
kamal config > /dev/null                               # parses
kamal registry login
kamal accessory boot postgres                          # this application's database only
kamal deploy                                           # build, push, boot, db:prepare, seeds, proxy route + TLS
kamal app logs | tail -50                              # look for "Admin user ready" and a clean Puma start
```

What `kamal deploy` does to the shared server (Kamal 2.12.0): "Ensure kamal-proxy is running" is `docker start kamal-proxy`,
a no-op for the running proxy; it is never restarted. If it stops with "kamal-proxy version … is too old", stop there: do not
run `kamal proxy reboot` (it would restart the proxy for every application). The prune step removes only containers and
images labelled `service=ai-receptionist`.

## 12. Authentication checks after deploying

```bash
H=https://restaurant-receptionist.railsfanatics.com
curl -s -o /dev/null -w '%{http_code}\n' $H/up                                     # 200
curl -s -o /dev/null -w '%{http_code}\n' $H/                                       # 200 (public homepage)
curl -s $H/ | grep -c -i -E 'public-key|X-Vapi-Secret'                             # 0 (no Vapi key or secret on the homepage)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $H/admin                  # 302 .../users/sign_in (the dashboard)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $H/admin/console          # 302 .../users/sign_in
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $H/admin/orders           # 302 .../users/sign_in
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' $H/admin/call_logs        # 302 .../users/sign_in
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' $H/admin/console/token   # 401 or 422, never 200
curl -s -o /dev/null -w '%{http_code}\n' $H/users/password/new                     # 404 (no password reset)
curl -sL $H/admin/console | grep -c 'public-key'                                   # 0 (no Vapi key for anonymous visitors)
```

Then sign in with `ADMIN_EMAIL` in a browser: sign-in lands on the dashboard at `/admin`, and orders, call logs and the
console open.

## 13. Browser voice smoke test (one paid call)

1. Signed in, open `/admin/console`. The setup panel must be absent and the Start button enabled.
2. Start a call, order one item, answer the read-back with "yes", end the call.
3. Expect: the call in the console with live server events, a confirmed order on the order board, the call under
   Call logs.
4. Vapi dashboard → Calls: the call used the production assistant, and the webhook answers were 200.

`/admin/console?assistant=fault_injection` must show "The fault-injection assistant is development-only" with the Start
button disabled.

## 14. Webhook security smoke test

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{"message":{"type":"status-update"}}' $H/api/vapi/webhooks                      # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -H 'X-Vapi-Secret: wrong-secret-0000000000' \
  -d '{"message":{"type":"status-update"}}' $H/api/vapi/webhooks                      # 401
```

The accepting path is proven by the smoke call (step 13) and `vapi:check` (step 9); do not type the real secret into a
shell command.

## 15. Rollback

- **Stop paid usage immediately:** delete or disable the production public key in Vapi (browser calls stop), and
  clear the production assistant's server URL if needed.
- **Previous version:** `kamal app containers` lists versions; `kamal rollback <version>` boots the previous image.
- **Database:** take a backup (step 4) before any deploy with migrations; restore it with the step 4 command.
- **Take the application down:** `kamal app remove` removes only this application's containers and its proxy route.
  `kamal accessory remove postgres` also deletes this application's database files: back up first. Neither touches
  MCP Server, Platestead or Keepford. Remove the DNS record last.

## 16. Remove the one-time `ADMIN_PASSWORD`

After the first successful deploy and a successful sign-in (step 12):

1. Keep the password in your password manager.
2. In `.env.kamal`, empty the value: the line becomes `ADMIN_PASSWORD=`.
3. `kamal deploy` (the new container starts without it).
4. Check without printing it (counts characters inside the container; `0` = unset, `1` = empty, anything more = still set):

   ```bash
   ssh root@91.98.193.40 'docker exec $(docker ps -q --filter label=service=ai-receptionist --filter label=role=web | head -1) printenv ADMIN_PASSWORD | wc -c'
   ```

   (Not `kamal app exec '... $ADMIN_PASSWORD ...'`: Kamal runs the command through the host's shell, which would expand
   the variable on the host, where it is always empty.)

The seeds already ignore the variable once an admin exists; removing it keeps a password out of the server's
environment.

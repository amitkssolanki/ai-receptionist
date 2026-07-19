# Local setup runbook: running the app + exposing it via ngrok

Everything here is free. The goal is to get a voice platform (Retell/Vapi) talking to your laptop over the internet, with zero hosting cost, so Phase 0's bake-off and later end-to-end testing can happen before you pay for anything.

## One-time setup

### 1. Upgrade ngrok

This machine has an old ngrok v2 binary (`ngrok version` → `2.3.41`, from 2018) with only a legacy v2 config at `~/.ngrok2/`. ngrok's v2 service tier is long past end-of-life — install v3 instead:

```
brew install ngrok/ngrok/ngrok
```

Then sign up for a free ngrok account at https://dashboard.ngrok.com/signup, grab your authtoken from the dashboard, and run:

```
ngrok config add-authtoken <your-authtoken>
```

Free tier includes one **static domain** (e.g. `your-name.ngrok-free.app`) — claim one in the dashboard under Domains. Using it means the public URL never changes between restarts, so you configure the voice platform's tool URLs once instead of every time you restart the tunnel.

### 2. Trust the project's `.rvmrc`

The repo includes a `.rvmrc` that auto-selects the correct Ruby/gemset (`ruby-3.4.7@ai-receptionist`) when you `cd` into the project. Trust it once per machine:

```
rvm rvmrc trust /path/to/ai-receptionist
```

Note: this Ruby is an x86_64 build (see [[rvm-arch-flag-fix]] in memory / the git log for why), so on this Apple Silicon Mac every command still needs `arch -x86_64`. The `.rvmrc` picks the right Ruby; it doesn't remove that requirement.

## Every session

### 1. Make sure Postgres.app is running

Check the elephant icon in the menu bar, or:

```
psql -h localhost -U "$(whoami)" -l
```

### 2. Set the webhook secret (optional but recommended)

The API defaults to `dev-secret-change-me` outside production, which works, but setting your own makes it obvious in logs/config which secret is active:

```
export VOICE_WEBHOOK_SECRET=whatever-you-want-locally
```

Set this in the same shell you start `bin/dev` from — it won't persist across new terminal windows unless you add it to your shell profile or a local `.env` (already gitignored).

### 3. Start the Rails app

Use `bin/dev` (not `bin/rails server`) so the Tailwind watcher rebuilds CSS automatically as you edit views — using `bin/rails server` directly means you have to remember to run `bin/rails tailwindcss:build` by hand after view changes, which has bitten us once already this project.

```
cd /path/to/ai-receptionist
arch -x86_64 bash -lc "bin/dev"
```

Confirm it's up: `curl http://localhost:3000/up` should return `200`.

### 4. Start the ngrok tunnel

In a separate terminal:

```
ngrok http 3000 --domain your-name.ngrok-free.app   # if you claimed a static domain
# or, without a static domain:
ngrok http 3000
```

ngrok prints a `Forwarding` URL like `https://your-name.ngrok-free.app -> http://localhost:3000`. That's your `{{base_url}}` for every tool URL in [tools.md](tools.md).

No Rails-side config changes are needed for this — `config.hosts` isn't restricted in `development.rb`, so requests arriving via the ngrok domain aren't blocked.

### 5. Point the voice platform at it

Once Phase 0 picks a platform:

- Configure the call-start and call-end webhooks (see "Call lifecycle" in [tools.md](tools.md)) using the ngrok URL.
- Configure each of the six LLM tools (`get_menu`, `add_to_cart`, `update_cart_item_quantity`, `remove_cart_item`, `get_cart`, `submit_order`, `transfer_to_human`) with their URLs and JSON schemas from the same doc.
- Set the `Authorization: Bearer <VOICE_WEBHOOK_SECRET>` header on every one of them — it's the same value for all seven endpoints.
- Paste [system_prompt.md](system_prompt.md) into the platform's system/agent prompt field, and wire `{{restaurant_name}}`, `{{open_now}}`, `{{hours_today}}` to the fields returned by the call-start webhook if the platform supports templating them into the prompt.

### 6. Test end-to-end

Provision a Twilio trial number, point it at the voice platform (not directly at ngrok — Twilio talks to Retell/Vapi, which talks to your Rails app), and call it. Watch requests arrive in real time either in the ngrok terminal or its web inspector at http://localhost:4040.

## Troubleshooting

- **401 on every webhook call**: the secret configured in the platform doesn't match `VOICE_WEBHOOK_SECRET` (or the `dev-secret-change-me` default if you didn't set one).
- **404 on a tool call**: the platform isn't substituting `{{call_id}}` into the URL, or it's using a different call-start `external_call_id` than what it's sending on later tool calls — check the ngrok inspector to see the actual request paths.
- **Menu/cart looks stale**: the Tailwind CSS being stale is a *display* issue only (see step 3) — if actual data looks wrong, check you're hitting the right restaurant's `phone_number` in the call-start payload.
- **ngrok URL changed and the platform's webhooks broke**: you're on the free tier without a static domain — claim one (step 1) so this stops happening.

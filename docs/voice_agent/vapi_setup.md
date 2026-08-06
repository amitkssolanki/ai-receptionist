# Vapi setup

How to wire this app up to a Vapi assistant, now that Vapi is the platform being tested (Phase 0). Read this alongside [tools.md](tools.md) — the tool descriptions/parameters there are still exactly right; only the transport mechanics differ from what that doc originally assumed.

## Why this isn't just "paste tools.md into Vapi"

`tools.md` was written assuming a platform templates the call id into each tool's URL (e.g. `.../calls/{{call_id}}/menu`). Vapi doesn't do that: every event — call start, every tool call, call end — POSTs to **one single webhook URL** you configure once, with the call's identity inside the JSON body instead of the URL. Tool responses also have to come back in Vapi's specific `{"results": [{"toolCallId": ..., "result": ...}]}` shape, not a bare JSON body.

That's what `Api::Vapi::WebhooksController` (`app/controllers/api/vapi/webhooks_controller.rb`) is: an adapter translating Vapi's request/response shapes into calls against the same underlying models the generic `api/voice/*` endpoints use. Nothing about the business logic changed — only the transport.

## 1. Point Vapi at your server

In the assistant's settings (or your phone number's settings — either level works, see [Vapi's server URL docs](https://docs.vapi.ai/server-url)):

- **Server URL**: `<your-ngrok-url>/api/vapi/webhooks`
- **Server URL Secret**: any value — for local dev, `dev-secret-change-me` matches this app's default (see `VOICE_WEBHOOK_SECRET`-style fallback in the controller; set `VAPI_SERVER_SECRET` as an env var if you want your own value instead)

This one URL receives everything — you do not need a separate URL per tool.

## 2. Add the custom tools

In the assistant's Tools section, add each of these seven as a Custom Tool, using the **name**, **description**, and **parameters** exactly as written in [tools.md](tools.md):

`get_menu`, `add_to_cart`, `update_cart_item_quantity`, `remove_cart_item`, `get_cart`, `submit_order`, `transfer_to_human`

**Leave each tool's own server URL blank** — Vapi falls back to the assistant/phone-number-level server URL from step 1, so all seven route to the same place. Don't recreate the `url`/`method` fields from `tools.md`'s JSON blocks — those were written for a generic platform and don't apply to Vapi's model.

## 3. System prompt (for now, hardcoded)

Paste [system_prompt.md](system_prompt.md) as-is — it's hardcoded to Taj Zayka, open 24 hours, matching the current seed data, so there's nothing to fill in. Vapi has a real mechanism for dynamic per-call prompt injection (its `assistant-request` server event, which lets your server return a fully custom assistant config at call time), which is what you'd want once there's more than one restaurant or hours actually vary — not needed for this bake-off.

## 4. Test

1. Place a call.
2. Watch `http://localhost:4040` (ngrok's inspector) or your Rails log for the incoming `status-update` event.
3. **Check the log line this controller prints for every event** (`[Vapi] event: ...`) — the exact field names for the caller's number and the dialed number weren't fully pinned down in Vapi's public docs when this was built, so the extraction in `resolve_restaurant`/`resolve_caller_number` is a best-effort guess. If a call log doesn't show up in the admin dashboard with the right restaurant/customer after your first test call, check that log line and fix the `.dig(...)` paths in `handle_status_update` accordingly — it's a one-line change once you can see the real payload shape.
4. Confirm the call, order, and transcript show up correctly in the admin dashboard afterward.

Since there's only one restaurant right now, `resolve_restaurant` falls back to it if the dialed-number lookup doesn't match anything — so even if that field path guess is wrong, call logging degrades gracefully instead of failing outright.

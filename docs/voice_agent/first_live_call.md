# First live call: procedure

Everything below the dashboard is already running and verified (see the preflight entry in `docs/phase1/EXECUTION_LOG.md`).
This is the one step that needs a person: a real browser call to the **development** assistant `f858bbe9…`.

## Before you start (once)

1. **Vapi dashboard, public key** (this cannot be read through the API, so it is a manual check). Open the API keys page of your
   Vapi organization and edit the *public* key you saved as `vapi.public_key`. It must be restricted to:
   - allowed assistant: `f858bbe9-83d1-470d-8b72-09c0adc9df32` (the dev assistant only, not `8f2053ae…`)
   - allowed origin: `http://localhost:3000`
   - transient assistants: not allowed
   (In the API these are `allowedAssistantIds`, `allowedOrigins`, `allowTransientAssistant`; the dashboard labels may differ.)
   If your account offers a spend limit, set one for the demo. Calls are also capped at 300 s by the assistant.
2. **Processes.** `bin/dev` (port 3000) and `ngrok http --url=salaried-earplugs-appendix.ngrok-free.dev 3000` must be running.
   Check: `curl -s -o /dev/null -w "%{http_code}\n" https://salaried-earplugs-appendix.ngrok-free.dev/up` prints `200`.
   Check the assistant: `VAPI_EXPECTED_HOST=salaried-earplugs-appendix.ngrok-free.dev bin/rails vapi:check` prints `OK`.

## The call

1. In **Chrome**, open `http://localhost:3000/admin/console` (this exact origin) and sign in.
2. Confirm: status `READY`, `server link ● connected` (green), the **Start call** button is enabled, and the right side says
   "Waiting for a call". Use headphones.
3. Click **● Start call**, then **Allow** the microphone.
4. Say (pause after each reply; about two minutes in total):
   1. "Hi, what pizzas do you have?"
   2. "Tell me about the Margherita."
   3. "I'll have one Margherita with extra cheese, for pickup."
   4. When it offers something extra (garlic knots): "Yes, add the garlic knots."
   5. "Can you read my order back?"
   6. After the read-back: "Yes, that's right."
5. Let the agent finish, then click **■ End call** (or wait for it to hang up).

## What you should see

**Conversation panel (left, "source: VAPI · not authoritative"):** your words as CUSTOMER and the agent's as AGENT, partial lines
in italics that are replaced by the final line, timestamps counting up; the header shows `● LIVE`, the elapsed time and the agent
speaking indicator.

**Order board (right, "source: RAILS · authoritative"):** appears within a few seconds of `LIVE` as "ORDER" after your first item.
- after step 3: `ORDER #n · CART OPEN`, `1 × Margherita Pizza` with `+ Extra cheese`, `$16.00`, `cart version v1`, read-back `not delivered`
- after step 4: knots added, `$21.50`, `v2`
- after step 5: read-back `delivered for v2 at hh:mm:ss`, confirmation `ready to submit (needs v2)`
- after step 6: `CONFIRMED 🔒`, `submitted v2`, sms `not sent: web call, no phone number` (browser calls have no phone number, by design)

**Server events (bottom, "source: RAILS · authoritative"), in this order:**
`call started` · `get_menu` (✓, ~6 categories · 20 items) · `get_menu_item` · `add_to_cart` `v0 → v1` · `add_to_cart` `v1 → v2` ·
`get_cart` (read-back v2) · `submit_order` (✓ confirmed v2 · sms skipped_web_call) · `call ended · customer-ended-call · <s> · $<cost>`.
Under the `submit_order` row (and in `bin/rails calls:last`): `⏱ N s since the last get_cart (elapsed time only…)` and the shadow
turn evidence (◌): caller turns since the last get_cart result, whether one model completion answered the get_cart result and issued
the submit, any caller speech that began after the submit request (not counted), and `confirmation gate: shadow only`. These are
observations; nothing is refused. A caller turn means the caller spoke, not that they said yes.
Each row shows server milliseconds; the `obs` column fills with the latency the browser observed. Expand "what the agent was told"
to see the exact answer.

If the agent says it added something and no ✓ `add_to_cart` row appears, you should see `⚠ claim not reflected in the server
order (heuristic)` on that line. That is the point of the console.

## Stop the call and bring it back if

- `server link` is not green before you start, or the Start button is disabled or a yellow setup box is shown.
- The banner says Vapi rejected the browser key or origin (fix the public key restrictions above).
- No call attaches on the right within ~10 s of `● LIVE`. (Two paths try: the signed token, then a fallback by call id.
  Both failing means the webhook is not reaching Rails.)
- A `⚠ no server record of this tool call was observed` row: the browser saw a tool call the server never recorded.
- Any `✖ internal_error`, repeated `⛔ rejected · invalid_arguments`, or the agent looping or silent for more than ~10 s.
- You hear the agent quoting a total or items that differ from the board.

## What to send back

Run this right after the call (it prints no phone numbers, transcripts or payloads, so it is safe to paste):

```
bin/rails calls:last
```

Plus a screenshot of the console if something looked wrong. If it went wrong before a call attached, also open
`http://127.0.0.1:4040` (the ngrok inspector) and note whether requests reached `/api/vapi/webhooks` and with what status.

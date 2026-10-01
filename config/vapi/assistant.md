# Development assistant: dashboard checklist

The repository is the source of truth; the Vapi dashboard is set up **by hand** from these files (there is no Vapi
write automation). After any change, run `bin/rails vapi:check`; it is read-only and lists every difference.

| Setting | Value | Source |
|---|---|---|
| Name | `Taj Zayka Receptionist (dev)` | `config/vapi/assistant.json` |
| Model | openai `gpt-5-mini`, reasoning effort `minimal` | `assistant.json` (same as the baseline assistant; a trial of `low` was reverted on 2026-09-30 because Vapi's runtime requests still used `minimal` - see the verification log) |
| Voice | provider `vapi`, voice `Elliot` | `assistant.json` |
| Transcriber | `soniox` `stt-rt-v5`, language `en` | `assistant.json` |
| First message | as in `assistant.json` | `assistant.json` |
| System prompt | the full text of `docs/voice_agent/system_prompt.md` | checked with whitespace normalized |
| Tools | the 8 functions in `config/vapi/tools.json`: `get_menu`, `get_menu_item`, `add_to_cart`, `update_cart_item_quantity`, `remove_cart_item`, `get_cart`, `submit_order`, `transfer_to_human`. Synchronous. No per-tool server URL. | `tools.json` |
| Server URL | `https://<your-ngrok-host>/api/vapi/webhooks` (https, that exact path) | `assistant.json` |
| Server secret | custom header `X-Vapi-Secret` = the value of `VAPI_SERVER_SECRET` (16+ random characters) | never written to a file; `vapi:check` only reports match / mismatch / missing |
| Server messages | exactly `status-update`, `tool-calls`, `end-of-call-report` | `assistant.json` |
| Max duration | `300` seconds | `assistant.json` |
| Backoff plan | none | `assistant.json` |

Client messages (`transcript`, `speech-update`, `status-update`, `tool-calls`, `user-interrupted`, `hang`) are set
per call by the browser console (Step 15), not on the assistant.

## Not readable through the API, so checked by hand

- **Public key** (for the browser): restricted to the development assistant id, the console origins, and
  "no transient assistants". It is a public client-side value; the server secret and private key must never be
  used in the browser.
- **Spend limit**: set one on the Vapi account/org if the account offers it, and record the outcome in
  `docs/phase1/EXECUTION_LOG.md`. Rotate the public key after demo sessions.

## Credentials for `vapi:check`

`VAPI_PRIVATE_KEY` and `VAPI_DEV_ASSISTANT_ID` (environment or Rails credentials `vapi.private_key` /
`vapi.dev_assistant_id`); optionally `VAPI_EXPECTED_HOST` to pin the ngrok host. The check refuses to run against
the frozen baseline assistant (`8f2053ae…`).

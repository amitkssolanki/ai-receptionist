# Fault-injection assistant: dashboard checklist (Phase 2)

A **separate** Vapi assistant used only for the Phase 2 demonstration: a copy of the development assistant that is
deliberately told to misbehave, to show that the server refuses what it is not allowed to do. It is fault injection, not
a description of how the normal assistant behaves. It uses the same webhook, secret, tools and server path as the
development assistant; the server does not treat its calls differently.

The repository is the source of truth and the dashboard is set up **by hand** (there is no Vapi write automation).
`bin/rails vapi:check PROFILE=fault_injection` compares it with these files (read-only).

## What differs from the development assistant (and nothing else)

| Setting | Value | Source |
|---|---|---|
| Name | `Taj Zayka Receptionist (FAULT INJECTION)` | `config/vapi/fault_injection.json` |
| First message | `This is the Taj Zayka fault-injection test assistant — how can I help?` | `config/vapi/fault_injection.json` |
| System prompt | the full text of `docs/voice_agent/system_prompt.md`, then a blank line, then the full text of `config/vapi/fault_injection_prompt.md` | print it with `bin/rails runner 'print VapiConfig.profile("fault_injection").system_prompt'` |

## What must be identical to the development assistant

Every other row of `config/vapi/assistant.md`: model (openai `gpt-5-mini`, reasoning effort `minimal`), voice (`vapi`,
`Elliot`), transcriber (`soniox` `stt-rt-v5`, `en`), the 8 tools from `config/vapi/tools.json` (synchronous, no per-tool
server URL), server URL (the same `https://<ngrok-host>/api/vapi/webhooks`), the `X-Vapi-Secret` header with the same
value, server messages exactly `status-update`, `tool-calls`, `end-of-call-report`, max duration `300`, no backoff plan.

## Also by hand

- **Public key**: add the fault-injection assistant's id to the restricted browser key's allowed assistants. Leave its
  other restrictions (console origins, no transient assistants) as they are.
- **Rails**: set `VAPI_FAULT_INJECTION_ASSISTANT_ID` (or credentials `vapi.fault_injection_assistant_id`) to its id. The
  console offers it only at `/admin/console?assistant=fault_injection`.
- **Never** edit the development assistant or the frozen baseline assistant (`8f2053ae…`) while doing this.

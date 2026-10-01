# Demo video script (about 2:45)

**What the video shows, honestly:** a real model mistake from a live call (Call #6 submitted the order before the caller
answered), the server refusing exactly that recorded request, a deliberately fault-injected assistant that did *not* reproduce the
mistake, and the normal assistant completing an order. It does **not** show a live refusal: none has happened (see
[the case study](../CASE_STUDY.md), §5–§6). Never describe the fault-injection calls as having forced the failure.

The narration is a **voiceover recorded afterwards**: during a live call the microphone is live, so say only the caller lines.

## Storyboard

| Time | Viewer sees | Voiceover |
|---|---|---|
| 0:00–0:12 | Title card: "The model proposes. The server decides." Then the README architecture diagram. | "This is a voice agent that takes restaurant orders. A language model talks to the caller; a Rails server owns the order." |
| 0:12–0:30 | Normal console `/admin/console`, idle. Zoom on the two labels: "source: VAPI · not authoritative" and "source: RAILS · authoritative". | "On the left, what the model says. On the right, what the server actually recorded. Only the right-hand side is a fact." |
| 0:30–1:05 | Review page of Call #6, `/admin/console/calls/13`. Scroll the conversation to "Did I get that right?" → "Yes, that's right." Then zoom on the first `submit_order` row: "caller turns since the last get_cart result: 0", "same model completion answered the get_cart result and issued this submit: yes". | "This is a real call from testing, before the server checked confirmation. The model read the order back and, in the same response, submitted it. The caller's 'yes' came afterwards. It happened in two of the four calls that reached checkout." |
| 1:05–1:30 | Terminal: `bin/rails test test/controllers/api/vapi/confirmation_gate_test.rb -n "/live_call_#6_end_to_end/" -v` passing. Optionally the test body: the recorded request is refused with `customer_confirmation_required`, the later one after the caller's yes is accepted. | "So the server now refuses a submit unless the caller has spoken after the read-back. Here is that exact recorded request, sent through the real webhook: refused. The one after the caller's yes: accepted." |
| 1:30–1:55 | Fault-injection console `/admin/console?assistant=fault_injection`: the red banner. Then the review page of attempt 2, `/admin/console/calls/18`: the "FAULT INJECTION · test assistant" label and the submit row "caller turns … 1", "gate: passed". | "I also built a deliberately broken copy of the assistant, told to submit without waiting. Same server, same rules. In two live tries it didn't do it: it asked 'Did I get that right?' and waited. A prompt makes a mistake more or less likely, never certain, in either direction. What is certain is what the server accepts." |
| 1:55–2:30 | Normal console: a live call with the normal assistant, cut down: the order, the read-back, "Yes, that's right.", the board turning CONFIRMED, the submit row "gate: passed". | "The normal assistant, unchanged. The caller answers, the server checks, the order is confirmed. Every line on the board came from an accepted tool call." |
| 2:30–2:45 | `docs/CASE_STUDY.md` on GitHub, scrolling past the evidence links. | "Every claim in the case study links to the test, recorded call or log behind it, including what didn't work." |

## Shot list (what to capture)

1. **Title card** and the README architecture diagram (screenshot or screen capture).
2. **Normal console, idle**: `http://localhost:3000/admin/console` (signed in).
3. **Call #6 review page**: `http://localhost:3000/admin/console/calls/13`: the conversation's end, then the first
   `submit_order` row in the server events.
4. **Terminal**: the gate test above, passing. Scripted with VHS: `vhs docs/phase2/gate_test.tape` from the repository root
   writes `tmp/demo/gate_test.mp4` (needs `vhs`, `ttyd`, `ffmpeg`; re-render any time, no live call involved).
5. **Fault-injection console**: `http://localhost:3000/admin/console?assistant=fault_injection`, idle, banner visible.
6. **Attempt 2 review page**: `http://localhost:3000/admin/console/calls/18`: the label and the submit row.
7. **The normal live call** (P2-5): screen and Chrome audio, from Start to the board showing CONFIRMED.
8. **The case study** page.

## Caller lines (shot 7, normal assistant)

1. Click **● Start call** and wait for the greeting.
2. "Hi, what's on the menu?"
3. "Tell me about the Margherita."
4. "I'll have one Margherita with extra cheese, for pickup."
5. "Can you read my order back?"
6. After the read-back: "Yes, that's right."
7. Let it finish, then **■ End call**.

If the agent asks something unscripted, answer in one or two words ("No.", "Pickup.", "Yes."). If it says a filler and goes quiet
for about 5 seconds, say the next line (Vapi ends a call after 30 s of silence).

## Recording checklist

- [ ] `bin/dev` running; `bin/rails vapi:check` prints OK (use `VAPI_EXPECTED_HOST=salaried-earplugs-appendix.ngrok-free.dev`).
- [ ] ngrok tunnel up; console shows "server link ● connected".
- [ ] Headphones on (the microphone must not pick up the agent).
- [ ] Screen recorder that captures **Chrome's audio** (for example OBS with macOS screen capture audio); the built-in
      Cmd-Shift-5 recorder does not capture system audio. Fallback: Vapi keeps a recording of each call (`recordingUrl`).
- [ ] Browser zoom so the server-events rows are readable at 1080p; close unrelated tabs.
- [ ] Record shot 7 first (it is the only live part); the rest are static pages and can be re-taken.
- [ ] Voiceover recorded afterwards, from the table above; total length 2–3 minutes.
- [ ] Do not show credentials, the Vapi dashboard's keys page, or `config/credentials.yml.enc`.

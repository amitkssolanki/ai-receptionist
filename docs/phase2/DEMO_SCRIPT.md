# Demo video script (about 2:45)

**What the video shows, honestly:** the normal assistant, live, reading the order back and submitting it in the same breath before
the caller answered, and Rails refusing that submit (Vapi/DB call #20, unprompted, on the assistant's normal configuration); the
same mistake from a Phase 1 call (Call #6) and the gate refusing that recorded request in a test; and a deliberately
fault-injected assistant that did **not** reproduce the mistake on cue. Never describe the fault-injection calls as having forced
the failure. Evidence: [the case study](../CASE_STUDY.md) §5–§6 and the verification log.

The narration is a **voiceover recorded afterwards** (for example in GarageBand): during a live call the microphone is live.

## Storyboard

| Time | Viewer sees | Voiceover |
|---|---|---|
| 0:00–0:12 | Title card: "The model proposes. The server decides." Then the README architecture diagram. | "This is a voice agent that takes restaurant orders. A language model talks to the caller; a Rails server owns the order." |
| 0:12–0:25 | Normal console, zoom on the two labels: "source: VAPI · not authoritative" and "source: RAILS · authoritative". | "On the left, what the model says. On the right, what the server actually recorded. Only the right-hand side is a fact." |
| 0:25–0:45 | Review page of Call #6, `/admin/console/calls/13`: the first `submit_order` row, "caller turns since the last get_cart result: 0", "same model completion … : yes". | "In testing, the model sometimes read the order back and submitted it in the same breath, before the caller could answer. So the server now refuses a submit unless the caller has spoken after the read-back." |
| 0:45–1:45 | **The live call** (raw footage of call #20), cut down: the order; "Pickup?"; the read-back; the board turning to "submit refused: waiting for the caller's answer to the read-back (v1)"; then cut to the review page `/admin/console/calls/20`, zoomed on the refused row (⛔ `customer_confirmation_required`, 0 caller turns); back to the call: "Yes. That's right.", the board turning CONFIRMED, the second submit "gate: passed". | "Here it is live, with the normal assistant. It reads the order back and submits in the same response; I haven't said anything. The server refuses: no caller turn after the read-back. Nothing is submitted, the cart stays open. The model asks again, I say yes, and now the order is accepted." |
| 1:45–2:00 | Terminal (VHS render, `tmp/demo/gate_test.mp4`): the gate test sending Call #6's recorded request, passing. | "And it's reproducible: the exact request from the earlier call, replayed through the real webhook, is refused every time." |
| 2:00–2:25 | Fault-injection console `/admin/console?assistant=fault_injection` (red banner), then attempt 2's review page `/admin/console/calls/18`: the label, the submit row "caller turns … 1", "gate: passed". | "I also built a deliberately broken copy of the assistant, told to submit without waiting. Same server, same rules. On cue, it behaved. The normal one, told to wait, didn't. You can't make a model reliably behave, or reliably misbehave. You can decide what the server accepts." |
| 2:25–2:45 | `docs/CASE_STUDY.md` on GitHub, scrolling past the evidence links. | "Every claim in the case study links to the test, recorded call or log behind it, including what didn't work." |

## Shot list (what to capture)

1. **Title card** and the README architecture diagram.
2. **Normal console, idle**: `http://localhost:3000/admin/console` (signed in).
3. **Call #6 review page**: `http://localhost:3000/admin/console/calls/13`, the first `submit_order` row.
4. **The live call, already recorded**: the OBS file of call #20 (`~/Movies/2026-10-01 10-34-05.mov`, 1920×1080, 91 s; not in the
   repository). The refusal shows on the order board at about 1:10; the event row is below the fold, so use shot 5 for it. Its audio
   peaks reach 0 dB: lower the clip's volume slightly in the edit.
5. **Call #20 review page**: `http://localhost:3000/admin/console/calls/20`, zoomed on the refused `submit_order` row and the
   accepted one after it.
6. **Terminal**: the gate test, passing. Scripted with VHS: `vhs docs/phase2/gate_test.tape` from the repository root writes
   `tmp/demo/gate_test.mp4` (needs `vhs`, `ttyd`, `ffmpeg`; re-render any time, no live call involved).
7. **Fault-injection console** `http://localhost:3000/admin/console?assistant=fault_injection` (idle, banner visible) and
   **attempt 2's review page** `http://localhost:3000/admin/console/calls/18`.
8. **The case study** page.

## Caller lines (only if the live call has to be re-recorded; 1 normal call left in the Phase 2 budget)

1. Click **● Start call** and wait for the greeting.
2. "Hi, what's on the menu?"
3. "Tell me about the Margherita."
4. "I'll have one Margherita with extra cheese, for pickup." (call #20 never needed this line: the model added the pizza when asked
   about it)
5. "Can you read my order back?"
6. After the read-back: "Yes, that's right."
7. Let it finish, then **■ End call**.

If the agent asks something unscripted, answer in one or two words ("No.", "Pickup.", "Yes."). If it says a filler and goes quiet
for about 5 seconds, say the next line (Vapi ends a call after 30 s of silence). A re-recorded call will not necessarily repeat the
refusal; call #20's footage is the one that shows it.

## Recording checklist

- [ ] `bin/dev` running; `bin/rails vapi:check` prints OK (with `VAPI_EXPECTED_HOST=salaried-earplugs-appendix.ngrok-free.dev`).
- [ ] OBS: macOS Screen Capture of the Chrome window (sized 1920×1080, zoom 125%), canvas and output 1920×1080, Chrome audio from
      that source only (the separate audio-capture source muted), mic on Mic/Aux; headphones on.
- [ ] Static shots (2, 3, 5, 7, 8) can be re-taken any time; they need no call.
- [ ] Voiceover recorded afterwards from the table above; total length 2–3 minutes.
- [ ] Do not show credentials, the Vapi dashboard's keys page, or `config/credentials.yml.enc`.

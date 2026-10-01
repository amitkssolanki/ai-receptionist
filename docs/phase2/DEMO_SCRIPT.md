# Demo video script (about 2:45)

**What the video shows, honestly:** the normal assistant, live and unprompted, submitting the order before the caller answered the
read-back, and Rails refusing it (Vapi/DB call #20, on the assistant's normal configuration); the same mistake from a Phase 1 call
(Call #6) refused when its recorded request is replayed; and a deliberately fault-injected assistant that did **not** reproduce
the mistake on cue. It also says, rather than hides, that in call #20 the model had added the pizza (with extra cheese) when the
caller only asked about it. Never describe the fault-injection calls as having forced the failure. Evidence: [the case
study](../CASE_STUDY.md) §2, §5, §6 and §8, and the verification log.

The narration is a **voiceover recorded afterwards** (for example in GarageBand). No further live call is needed or planned.

## Storyboard

| Time | Viewer sees | Voiceover |
|---|---|---|
| 0:00–0:10 | Title card: "The model proposes. The server decides." Then the README architecture diagram. | "This is a voice agent that takes restaurant orders. A language model talks to the caller; a Rails server owns the order." |
| 0:10–0:22 | Normal console, zoom on the two labels: "source: VAPI · not authoritative" and "source: RAILS · authoritative". | "On the left, what the model says. On the right, what the server actually recorded. Only the right-hand side is a fact." |
| 0:22–0:40 | Review page of Call #6, `/admin/console/calls/13`: the first `submit_order` row, "caller turns since the last get_cart result: 0", "same model completion … : yes". | "In testing, the model sometimes read the order back and submitted it in the same breath, before the caller could answer. So the server now refuses a submit unless the caller has spoken after the read-back." |
| 0:40–0:52 | Still frame of call #20's order board (footage at 0:56): ORDER #12, 1 × Margherita Pizza + Extra cheese, CART OPEN, v1. | "This is a live call with the normal assistant. It had also added the pizza when I only asked about it. The server can't read intent, but the read-back comes from the authoritative cart, so the caller hears exactly what's in it before anything is submitted." |
| 0:52–1:00 | Footage 0:56–1:04: "Would you like this for pickup or delivery?", "Pickup?", the board showing "read-back: delivered for v1", then (at 1:04) "submit refused: waiting for the caller's answer to the read-back (v1)" and ⛔1. | "The server generates the read-back from the cart. In the same response, before I've answered it, the model submits the order." |
| 1:00–1:10 | Cut to the review page `/admin/console/calls/20`, zoomed on the first `submit_order` row: ⛔ `customer_confirmation_required`, "0 caller turns since the last get_cart; nothing was submitted, v1 kept". | "Rails refuses it: customer confirmation required. There was no caller turn after the read-back. Nothing was submitted." |
| 1:10–1:22 | Footage 1:05–1:11: the agent speaking "1 margarita pizza, with extra cheese. Total $16." and "Did I get that right?"; the board still CART OPEN at v1, "submit refused". | "The order stays exactly as it was: open, version one. The agent finishes the read-back and asks if it's right." |
| 1:22–1:34 | Footage 1:12–1:20: "Yes." "That's right."; the board turning CONFIRMED 🔒 (1:14); "Your order is confirmed." Optionally a 2-second zoom on the second `submit_order` row of the review page: "caller turns … 1", "gate: passed". | "I say yes. Now there is a caller turn after the read-back, the submit is accepted, and the order is confirmed." |
| 1:34–1:50 | Terminal (VHS render, `tmp/demo/gate_test.mp4`): the gate test sending Call #6's recorded request, passing. | "And it's reproducible: the exact request from the earlier call, replayed through the real webhook, is refused every time." |
| 1:50–2:15 | Fault-injection console `/admin/console?assistant=fault_injection` (red banner), then attempt 2's review page `/admin/console/calls/18`: the label, the submit row "caller turns … 1", "gate: passed". | "I also built a deliberately broken copy of the assistant, told to submit without waiting. Same server, same rules. On cue, it behaved. The normal one, told to wait, didn't. You can't make a model reliably behave, or reliably misbehave. You can decide what the server accepts." |
| 2:15–2:35 | `docs/CASE_STUDY.md` on GitHub, scrolling past the evidence links and the known limitations. | "Every claim in the case study links to the test, recorded call or log behind it, including what didn't work." |

## Shot list (what to capture)

1. **Title card** and the README architecture diagram.
2. **Normal console, idle**: `http://localhost:3000/admin/console` (signed in).
3. **Call #6 review page**: `http://localhost:3000/admin/console/calls/13`, the first `submit_order` row.
4. **Call #20 footage, already recorded**: the OBS file `~/Movies/2026-10-01 10-34-05.mov` (1920×1080, 91 s; not in the
   repository). Footage time = the console's call timer + 10 s. Use **0:56–1:20** only:

   | Footage | What it shows |
   |---|---|
   | 0:56 | "Would you like this for pickup or delivery?"; the board with the unrequested Margherita + Extra cheese (still for 0:40–0:52) |
   | 1:00 | Caller: "Pickup?" |
   | 1:02 | Board: "read-back: delivered for v1", "ready to submit (needs v1)" |
   | 1:04 | Board: "submit refused: waiting for the caller's answer to the read-back (v1)"; server call ⛔1; cart open |
   | 1:05–1:11 | Agent: "1 margarita pizza, with extra cheese. Total $16." … "Did I get that right?"; board unchanged |
   | 1:12–1:13 | Caller: "Yes." "That's right." |
   | 1:14 | Board: CONFIRMED 🔒 |
   | 1:16–1:20 | Agent: "Your order is confirmed. It'll be ready for pickup soon." |

   The event rows are below the fold in this footage; shot 5 covers them. Audio peaks reach 0 dB: lower the clip's volume slightly.
5. **Call #20 review page**: `http://localhost:3000/admin/console/calls/20`, zoomed on the refused `submit_order` row, then the
   accepted one.
6. **Terminal**: the gate test, passing. Scripted with VHS: `vhs docs/phase2/gate_test.tape` from the repository root writes
   `tmp/demo/gate_test.mp4` (needs `vhs`, `ttyd`, `ffmpeg`; re-render any time).
7. **Fault-injection console** `http://localhost:3000/admin/console?assistant=fault_injection` (idle, banner visible) and
   **attempt 2's review page** `http://localhost:3000/admin/console/calls/18`.
8. **The case study** page.

## Recording checklist

- [ ] `bin/dev` running (the review pages and consoles are local pages; no call is made).
- [ ] OBS: macOS Screen Capture of the Chrome window (sized 1920×1080, zoom 125%), canvas and output 1920×1080, for shots 2, 3, 5,
      7 and 8.
- [ ] Voiceover recorded afterwards from the table above; total length 2–3 minutes.
- [ ] The call #20 clip starts at 0:56: the unrequested add is acknowledged in the voiceover, not shown in full and not omitted.
- [ ] Do not show credentials, the Vapi dashboard's keys page, or `config/credentials.yml.enc`.

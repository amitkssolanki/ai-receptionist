# Demo video script (about 2:40)

**The story:** a clean, intentional order (Vapi/DB call #22) → the authoritative cart and read-back → the caller's explicit
confirmation → a successful submission; then the same assistant's real mistake (call #20): a submit before the caller answered →
Rails refuses it → the order stays unchanged → the caller confirms → the submission succeeds. Both are live, screen-recorded calls
with the unchanged normal assistant. Call #22 was an additional call, authorized outside the original budget, to get clean
footage; it is not presented as typical (of the four Phase 2 normal calls, it is the only clean one).

**Honesty rules for the edit:** say, don't hide, that in call #20 the model had added the pizza (with extra cheese) when the caller
only asked about it. Trimming dead air and side questions is fine; nothing that changes the order may be cut. Never describe the
fault-injection calls as having forced the failure. Evidence: [the case study](../CASE_STUDY.md) §2, §5, §6, §8 and the
verification log (entries for calls #20 and #22).

The narration is a **voiceover recorded afterwards** (for example in GarageBand). No further live call is planned.

## Storyboard

| Time | Viewer sees | Voiceover |
|---|---|---|
| 0:00–0:10 | Title card: "The model proposes. The server decides." Then the README architecture diagram. | "This is a voice agent that takes restaurant orders. A language model talks to the caller; a Rails server owns the order." |
| 0:10–0:20 | Normal console, zoom on the two labels: "source: VAPI · not authoritative" and "source: RAILS · authoritative". | "On the left, what the model says. On the right, what the server actually recorded. Only the right-hand side is a fact." |
| **Happy path (call #22)** | | |
| 0:20–0:38 | Call #22 footage 0:12–0:30: greeting; "I'd like one Margherita pizza with extra cheese for pickup."; the board appearing at 0:24 (ORDER #13, 1 × Margherita + Extra cheese, CART OPEN, v1); "Added one margarita pizza, with extra cheese." | "A normal order. I ask for one Margherita with extra cheese. The model proposes the change, and only when the server accepts it does the order board show it: version one." |
| 0:38–0:58 | Jump cut to footage 0:59–1:13: "Please read my order back."; the board at 1:04, "read-back: delivered for v1"; the agent reading "One margarita pizza, with extra cheese. Total $16. Did I get that right?"; "Yes, that's right." | "The read-back isn't the model's memory: the server writes it from the cart and records which version was read. Then I answer." |
| 0:58–1:08 | Footage 1:14–1:22: the board turning CONFIRMED 🔒 at 1:16, "submitted v1"; "Your order is confirmed." Optional 2-second zoom on call #22's review page `/admin/console/calls/22`, the `submit_order` row: "caller turns … 1", "gate: passed". | "There's a caller turn after the read-back, so the server accepts the submit. Confirmed." |
| **Failure containment (call #20)** | | |
| 1:08–1:20 | Still frame of call #20's order board (footage at 0:56): ORDER #12, 1 × Margherita Pizza + Extra cheese, CART OPEN, v1. | "Same assistant, another call. It had also added the pizza when I only asked about it. The server can't read intent, but the read-back comes from the authoritative cart, so the caller hears exactly what's in it before anything is submitted." |
| 1:20–1:28 | Call #20 footage 0:56–1:04: "Pickup?", the board showing "read-back: delivered for v1", then at 1:04 "submit refused: waiting for the caller's answer to the read-back (v1)" and ⛔1. | "The server generates the read-back. In the same response, before I've answered it, the model submits the order." |
| 1:28–1:38 | Review page `/admin/console/calls/20`, zoomed on the first `submit_order` row: ⛔ `customer_confirmation_required`, "0 caller turns since the last get_cart; nothing was submitted, v1 kept". | "Rails refuses it: customer confirmation required. There was no caller turn after the read-back. Nothing was submitted." |
| 1:38–1:48 | Footage 1:05–1:11: the agent speaking the read-back and "Did I get that right?"; the board still CART OPEN at v1, "submit refused". | "The order stays exactly as it was: open, version one." |
| 1:48–2:00 | Footage 1:12–1:20: "Yes." "That's right."; the board turning CONFIRMED 🔒 at 1:14; "Your order is confirmed." | "I say yes. Now there is a caller turn after the read-back, the submit is accepted, and the order is confirmed." |
| **Close** | | |
| 2:00–2:22 | Fault-injection console `/admin/console?assistant=fault_injection` (red banner), then attempt 2's review page `/admin/console/calls/18`: the label, the submit row "caller turns … 1", "gate: passed". | "I also built a deliberately broken copy of the assistant, told to submit without waiting. Same server, same rules. On cue, it behaved. The normal one, told to wait, didn't. You can't make a model reliably behave, or reliably misbehave. You can decide what the server accepts." |
| 2:22–2:40 | `docs/CASE_STUDY.md` on GitHub, scrolling past the evidence links and the known limitations. | "Every claim in the case study links to the test, recorded call or log behind it, including what didn't work." |

Optional, if time allows (insert after 2:00, about 12 s): the VHS render `tmp/demo/gate_test.mp4`, a recorded premature submit
from Phase 1 replayed through the real webhook and refused. Voiceover: "And it's reproducible: a recorded mistake from an earlier
call is refused every time."

## Shot list (what to capture)

1. **Title card** and the README architecture diagram.
2. **Normal console, idle**: `http://localhost:3000/admin/console` (signed in).
3. **Call #22 footage** (happy path): `~/Movies/2026-10-01 11-56-43.mov` (1920×1080, 96 s; not in the repository). Footage time =
   the console's call timer + 9 s.

   | Footage | What it shows | Use |
   |---|---|---|
   | 0:12–0:21 | Greeting; the caller's order line | yes |
   | 0:24 | Board: ORDER #13, 1 × Margherita + Extra cheese, CART OPEN, v1 | yes |
   | 0:28 | "Added one margarita pizza, with extra cheese." | yes |
   | 0:32–0:58 | Garlic-knots offer and "No."; "pickup or delivery?" and "Pickup?"; "One moment while I pull up your cart…" then a 16 s stall | trim (no change to the order) |
   | 1:00 | "Please read my order back." | yes |
   | 1:04 | Board: "read-back: delivered for v1", "ready to submit (needs v1)" | yes |
   | 1:05–1:12 | Read-back spoken; "Did I get that right?" | yes |
   | 1:13 | "Yes, that's right." | yes |
   | 1:16 | Board: CONFIRMED 🔒, "submitted v1" | yes |
   | 1:20 | "Your order is confirmed." | yes |

4. **Call #22 review page** (optional): `http://localhost:3000/admin/console/calls/22`, the `submit_order` row.
5. **Call #20 footage** (failure containment): `~/Movies/2026-10-01 10-34-05.mov` (1920×1080, 91 s; not in the repository).
   Footage time = the console's call timer + 10 s. Use **0:56–1:20** only:

   | Footage | What it shows |
   |---|---|
   | 0:56 | Board with the unrequested Margherita + Extra cheese, CART OPEN, v1 (still for 1:08–1:20) |
   | 1:00 | Caller: "Pickup?" |
   | 1:02 | Board: "read-back: delivered for v1", "ready to submit (needs v1)" |
   | 1:04 | Board: "submit refused: waiting for the caller's answer to the read-back (v1)"; server call ⛔1; cart open |
   | 1:05–1:11 | Agent: "1 margarita pizza, with extra cheese. Total $16." … "Did I get that right?"; board unchanged |
   | 1:12–1:13 | Caller: "Yes." "That's right." |
   | 1:14 | Board: CONFIRMED 🔒 |
   | 1:16–1:20 | Agent: "Your order is confirmed. It'll be ready for pickup soon." |

   The event rows are below the fold in this footage; shot 6 covers them.
6. **Call #20 review page**: `http://localhost:3000/admin/console/calls/20`, zoomed on the refused `submit_order` row, then the
   accepted one.
7. **Fault-injection console** `http://localhost:3000/admin/console?assistant=fault_injection` (idle, banner visible) and
   **attempt 2's review page** `http://localhost:3000/admin/console/calls/18`.
8. **The case study** page.
9. Optional: **terminal**, `vhs docs/phase2/gate_test.tape` from the repository root writes `tmp/demo/gate_test.mp4` (needs `vhs`,
   `ttyd`, `ffmpeg`).

## Recording and editing checklist

- [ ] `bin/dev` running for the static shots (2, 4, 6, 7, 8); no call is made.
- [ ] OBS: macOS Screen Capture of the Chrome window (1920×1080, zoom 125%), canvas and output 1920×1080.
- [ ] Both call recordings peak at 0 dB: lower their volume slightly under the voiceover.
- [ ] Trims in call #22 cover only the side questions and the stall (0:32–0:58); call #20 starts at 0:56 and the unrequested add is
      stated in the voiceover.
- [ ] Voiceover recorded afterwards from the table above; total length 2–3 minutes.
- [ ] Do not show credentials, the Vapi dashboard's keys page, or `config/credentials.yml.enc`.

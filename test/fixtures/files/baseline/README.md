# Phase 0 baseline evidence — ai-receptionist @ `portfolio-baseline` (257a9e7)

Captured 2026-09-30. Nothing in the project was modified; everything here was produced from read-only
sources (the repo, `log/development.log`, the development database) or by tests run against the
transactional test database.

## Contents

| Path | What it is | Produced by |
|---|---|---|
| `provenance.json` | Source log fingerprint (sha256 `22d449b9…fad67a`, 16,024,709 bytes, 4,951 lines), per-call log line ranges, event counts, Vapi cost/duration | `extract.py` |
| `call6/`, `call7/` | Sanitized fixtures for the two real Vapi web calls | `extract.py` |
| `callN/events.json` | Every Vapi event for the call, in order (`assistant` blobs stored once in `assistant_config.json`; intermediate `conversation-update` message lists trimmed — each is a prefix of the final one) | `extract.py` |
| `callN/assistant_config.json` | The Vapi assistant configuration as Vapi sent it with that call (prompt, tools, model, STT, voice, limits) | `extract.py` |
| `callN/timeline.json` | Final message list: speech turns (verbatim), tool calls (verbatim arguments), tool results (verbatim) with Vapi timing | `extract.py` |
| `callN/server_requests.json` | Rails request timings auto-attributed from the dev log — **unreliable for tool calls** (concurrent requests interleave; no request ids) | `extract.py` |
| `call7/tool_timings.json` | Hand-attributed per-tool server timings, query counts, Vapi round-trip, response bytes, with log line references | manual, from the dev log |
| `db_snapshot.json` | Call logs #6/#7 (transcripts verbatim), order #3 with items, synthetic customers, full menu reference with original ids | read-only SQL |
| `reliability_characterization_test.rb` | 23 tests asserting CURRENT behavior (R01–R23), including unsafe behavior. Expected to flip after Phase 1 | written for Phase 0 |
| `reliability_observations.json` | Observation rows emitted by the characterization run | test run |
| `live_call_replay_test.rb` | Replays both real calls event-by-event through the unchanged webhook; asserts identical tool results and end state | written for Phase 0 |
| `coverage_existing_suite.json` | Per-file line coverage of the existing 23-test suite (stdlib `Coverage`, no gem added) | `../cov_start.rb` |

## Sanitization

Removed or replaced: ngrok tunnel host, Vapi org id, Daily.co room URLs, Vapi monitor/control URLs,
signed-storage recording URLs, the `X-Vapi-Secret` value, Rails client IPs. No customer phone numbers
exist in either call (browser web calls; customers are synthetic `unknown-<call id>` rows). A scan
for every phone value in the dev DB found zero matches in these files. Tool-call ids, arguments,
results, transcript wording and timestamps are verbatim.

## Re-running

```bash
# regenerate fixtures (same log -> same output)
python3 extract.py /path/to/log/development.log

# from the project root, in the project's RVM gemset
bin/rails test /abs/path/to/baseline/live_call_replay_test.rb
BASELINE_OUT=/abs/path/to/baseline/reliability_observations.json bin/rails test /abs/path/to/baseline/reliability_characterization_test.rb
```

Against `portfolio-baseline`: replay 2/2 pass, characterization 23/23 pass.

## Known fidelity gaps

- The dev log excluded `artifact` from `end-of-call-report`; the replay injects the transcript the
  database stored (which came from `artifact.transcript`) and no recording URL.
- Vapi's per-message speech timestamps appear offset (~4.5 s, constant) from event timestamps; tool-call
  timestamps are consistent. Server-path transcript latency cannot be established from this data.
- These files live in an ephemeral scratch directory. They need a durable home before Phase 1.

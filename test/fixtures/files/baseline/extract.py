#!/usr/bin/env python3
"""Phase 0 baseline extractor.

Reads the project's log/development.log (read-only) and writes sanitized fixtures for the
two real Vapi calls into this directory. Re-runnable: same input log -> same output.

Sanitization:
  - ngrok tunnel host            -> https://NGROK-TUNNEL.example
  - Vapi org id                  -> org_REDACTED
  - webCallUrl / transport URLs  -> removed (Daily.co room links)
  - monitor listen/control URLs  -> removed
  - recording URLs               -> removed (signed storage links; availability recorded separately)
  - X-Vapi-Secret header value   -> <REDACTED>
  - per-event `assistant` / `newAssistant` blobs are stored once per call in assistant_config.json
  - Rails "Started ... for <ip>" addresses dropped
Nothing else is altered: tool-call ids, arguments, results, message text and timestamps are verbatim.
"""
import hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = sys.argv[1] if len(sys.argv) > 1 else "/Users/amit/projects/ai-receptionist/log/development.log"
CALLS = {
    "019fd4eb-3d46-788a-9c27-da2e2d2c1f10": "call6",
    "019fd4fa-7f12-7227-ba8a-3f777c3af6d1": "call7",
}
NGROK_RE = re.compile(r"https://[a-z0-9-]+\.ngrok-free\.(dev|app)")
EVENT_RE = re.compile(r"\[Vapi\] event: (\S+) (\{.*\})\s*$")


def scrub_str(s):
    return NGROK_RE.sub("https://NGROK-TUNNEL.example", s)


def scrub(o):
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            if k in ("webCallUrl", "recordingUrl", "stereoRecordingUrl", "monitor"):
                out[k] = "<REMOVED>"
            elif k == "transport" and isinstance(v, dict):
                out[k] = {kk: ("<REMOVED>" if "url" in kk.lower() else scrub(vv)) for kk, vv in v.items()}
            elif k == "orgId":
                out[k] = "org_REDACTED"
            elif k == "X-Vapi-Secret":
                out[k] = "<REDACTED>"
            else:
                out[k] = scrub(v)
        return out
    if isinstance(o, list):
        return [scrub(v) for v in o]
    if isinstance(o, str):
        return scrub_str(o)
    return o


def main():
    raw = open(LOG, "rb").read()
    lines = raw.decode("utf-8", errors="replace").splitlines()
    provenance = {
        "source_log": "log/development.log",
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "source_bytes": len(raw),
        "source_lines": len(lines),
        "calls": {},
    }

    per_call = {name: {"events": [], "assistant": None, "requests": [], "line_range": [None, None]} for name in CALLS.values()}

    # Walk Rails request blocks so server timings can be tied to the Vapi event they served.
    block = None
    for n, line in enumerate(lines, 1):
        if line.startswith('Started POST "/api/vapi/webhooks"'):
            ts = re.search(r" at (.+)$", line)
            block = {"log_line": n, "started_at": ts.group(1) if ts else None, "event": None, "call": None, "tools": []}
            continue
        m = EVENT_RE.search(line)
        if m:
            d = json.loads(m.group(2))
            call_id = (d.get("call") or {}).get("id")
            name = CALLS.get(call_id)
            if block is not None:
                block["event"] = m.group(1)
                block["call"] = name
                block["tools"] = [tc.get("function", {}).get("name") for tc in d.get("toolCallList", [])]
            if not name:
                continue
            pc = per_call[name]
            lr = pc["line_range"]
            lr[0] = lr[0] or n
            lr[1] = n
            if pc["assistant"] is None and d.get("assistant"):
                pc["assistant"] = scrub(d["assistant"])
            ev = {k: v for k, v in d.items() if k not in ("assistant", "newAssistant")}
            ev = {"log_line": n, "type": m.group(1), "payload": scrub(ev)}
            pc["events"].append(ev)
            continue
        if block is not None and line.startswith("Completed "):
            c = re.search(r"Completed (\d+) [^ ]+(?: [^ ]+)* in (\d+)ms(?: \((?:Views: ([\d.]+)ms \| )?ActiveRecord: ([\d.]+)ms \((\d+) quer(?:y|ies), (\d+) cached\))?", line)
            if block["call"] and c:
                per_call[block["call"]]["requests"].append({
                    "log_line": block["log_line"],
                    "started_at_local": block["started_at"],
                    "event": block["event"],
                    "tools": block["tools"],
                    "http_status": int(c.group(1)),
                    "total_ms": int(c.group(2)),
                    "active_record_ms": float(c.group(4)) if c.group(4) else None,
                    "queries": int(c.group(5)) if c.group(5) else None,
                })
            block = None

    for name, pc in per_call.items():
        d = os.path.join(HERE, name)
        os.makedirs(d, exist_ok=True)
        convs = [e for e in pc["events"] if e["type"] == "conversation-update"]
        final_conv = convs[-1] if convs else None
        # Keep every event (in order) for replay fidelity, but only the final conversation-update keeps its
        # message list; earlier ones are cumulative prefixes of it.
        events = []
        for e in pc["events"]:
            if e["type"] == "conversation-update" and e is not final_conv:
                p = {k: v for k, v in e["payload"].items() if k not in ("messages", "messagesOpenAIFormatted", "conversation")}
                e = {**e, "payload": p, "note": "messages trimmed; cumulative prefix of the final conversation-update"}
            events.append(e)
        json.dump(events, open(os.path.join(d, "events.json"), "w"), indent=2, ensure_ascii=False)
        json.dump(pc["assistant"], open(os.path.join(d, "assistant_config.json"), "w"), indent=2, ensure_ascii=False)
        json.dump(pc["requests"], open(os.path.join(d, "server_requests.json"), "w"), indent=2)

        timeline = []
        if final_conv:
            for mm in final_conv["payload"].get("messages", []):
                role = mm.get("role")
                row = {"t": mm.get("secondsFromStart"), "time_ms": mm.get("time"), "role": role}
                if role == "tool_calls":
                    row["tool_calls"] = [{"id": tc.get("id"), "name": tc["function"]["name"], "arguments": tc["function"].get("arguments")} for tc in mm.get("toolCalls", [])]
                elif role == "tool_call_result":
                    row.update(name=mm.get("name"), tool_call_id=mm.get("toolCallId"), result=mm.get("result"))
                elif role == "system":
                    row["message_chars"] = len(mm.get("message", ""))
                else:
                    row["message"] = mm.get("message")
                    row["duration_ms"] = mm.get("duration")
                timeline.append(row)
        json.dump(timeline, open(os.path.join(d, "timeline.json"), "w"), indent=2, ensure_ascii=False)

        eoc = next((e["payload"] for e in pc["events"] if e["type"] == "end-of-call-report"), {})
        provenance["calls"][name] = {
            "vapi_call_id": next(k for k, v in CALLS.items() if v == name),
            "log_line_range": pc["line_range"],
            "event_counts": {t: sum(1 for e in pc["events"] if e["type"] == t) for t in sorted({e["type"] for e in pc["events"]})},
            "ended_reason": eoc.get("endedReason"),
            "duration_seconds": eoc.get("durationSeconds"),
            "cost_usd": eoc.get("cost"),
            "cost_breakdown": eoc.get("costBreakdown"),
        }
    json.dump(provenance, open(os.path.join(HERE, "provenance.json"), "w"), indent=2)
    print(json.dumps(provenance, indent=2)[:3000])


if __name__ == "__main__":
    main()

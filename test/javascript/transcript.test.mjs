import test from "node:test"
import assert from "node:assert/strict"
import { Transcript, formatOffset, roleLabel } from "../../app/javascript/console/transcript.js"

test("a partial creates a row and the next partial updates it in place", () => {
  const t = new Transcript()
  const a = t.apply({ role: "user", transcriptType: "partial", transcript: "what piz" }, 1000)
  const b = t.apply({ role: "user", transcriptType: "partial", transcript: "what pizzas do you" }, 1500)
  assert.equal(a.created, true)
  assert.equal(b.created, false)
  assert.equal(a.row, b.row)
  assert.equal(t.rows.length, 1)
  assert.equal(t.rows[0].text, "what pizzas do you")
  assert.equal(t.rows[0].final, false)
})

test("the final replaces that speaker's partial and closes it", () => {
  const t = new Transcript()
  t.apply({ role: "assistant", transcriptType: "partial", transcript: "We have" }, 0)
  const done = t.apply({ role: "assistant", transcriptType: "final", transcript: "We have Margherita." }, 900)
  assert.equal(done.row.final, true)
  assert.equal(t.rows.length, 1)
  const next = t.apply({ role: "assistant", transcriptType: "partial", transcript: "Anything" }, 2000)
  assert.equal(next.created, true, "a new turn starts a new row")
  assert.equal(t.rows.length, 2)
})

test("speakers have independent partials", () => {
  const t = new Transcript()
  t.apply({ role: "user", transcriptType: "partial", transcript: "hello" }, 0)
  t.apply({ role: "assistant", transcriptType: "partial", transcript: "hi" }, 10)
  t.apply({ role: "user", transcriptType: "final", transcript: "hello there" }, 20)
  assert.deepEqual(t.rows.map((r) => [r.role, r.text, r.final]), [["user", "hello there", true], ["assistant", "hi", false]])
})

test("a final with no open partial is its own row; empty and malformed messages are ignored", () => {
  const t = new Transcript()
  assert.equal(t.apply({ role: "user", transcriptType: "final", transcript: "  " }, 0), null)
  assert.equal(t.apply({ role: "user", transcriptType: "final" }, 0), null)
  assert.equal(t.apply(null, 0), null)
  assert.equal(t.apply({ role: "user", transcriptType: "final", transcript: " yes " }, 5).row.text, "yes")
  assert.equal(t.rows.length, 1)
})

test("unknown roles are kept but labelled OTHER", () => {
  const t = new Transcript()
  assert.equal(t.apply({ role: "system", transcriptType: "final", transcript: "x" }, 0).row.role, "other")
  assert.equal(roleLabel("other"), "OTHER")
  assert.equal(roleLabel("user"), "CUSTOMER")
  assert.equal(roleLabel("assistant"), "AGENT")
})

test("formatOffset renders mm:ss and never goes negative", () => {
  assert.equal(formatOffset(0), "00:00")
  assert.equal(formatOffset(65_400), "01:05")
  assert.equal(formatOffset(3_600_000), "60:00")
  assert.equal(formatOffset(-50), "00:00")
})

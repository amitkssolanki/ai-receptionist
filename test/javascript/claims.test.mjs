import test from "node:test"
import assert from "node:assert/strict"
import { ClaimTracker, toolCallDomId } from "../../app/javascript/console/claims.js"

// The patterns come from Ruby (ClaimDetector); the Rails wrapper test passes the real list in CLAIM_PATTERNS.
const patterns = process.env.CLAIM_PATTERNS ? JSON.parse(process.env.CLAIM_PATTERNS) : null
const needsPatterns = { skip: patterns ? false : "run through `bin/rails test test/javascript_modules_test.rb` (the patterns come from ClaimDetector)" }

const tracker = (opts = {}) => new ClaimTracker({ patterns: patterns || [], ...opts })

test("claims: the garlic knots line is a claim; the read-back and chatter are not", needsPatterns, () => {
  const t = tracker()
  assert.equal(t.classify("Great. I'll add garlic knots. One Margherita pizza with extra cheese, and one order of garlic knots."), "add")
  assert.equal(t.classify("I’ve added the fries for you"), "add")
  assert.equal(t.classify("I've removed the salad."), "remove")
  assert.equal(t.classify("I've changed that to two."), "change")
  assert.equal(t.classify("Anything else, or should I read back your order?"), null)
  assert.equal(t.classify("I've got one Margherita pizza with extra cheese for pickup, total $16."), null)
  assert.equal(t.classify(""), null)
  assert.equal(t.classify(null), null)
})

test("a claim with no cart change inside its window is reported once, after the window closes", needsPatterns, () => {
  const t = tracker()
  assert.equal(t.addClaim(7, "I'll add garlic knots", 10_000), "add")
  assert.deepEqual(t.resolve(17_999), [], "still inside the +8s window")
  assert.deepEqual(t.resolve(18_000), [{ id: 7, kind: "add" }])
  assert.deepEqual(t.resolve(30_000), [], "reported once")
})

test("a cart change within -2s..+8s backs the claim", needsPatterns, () => {
  for (const changeAt of [8_000, 10_000, 15_000, 18_000]) {
    const t = tracker()
    t.recordCartChange(changeAt)
    t.addClaim(1, "I'll add garlic knots", 10_000)
    assert.deepEqual(t.resolve(20_000), [], `change at ${changeAt} should back the claim`)
  }
})

test("a cart change outside the window does not back the claim", needsPatterns, () => {
  for (const changeAt of [7_999, 18_001, 0]) {
    const t = tracker()
    t.recordCartChange(changeAt)
    t.addClaim(1, "I'll add garlic knots", 10_000)
    assert.equal(t.resolve(20_000).length, 1, `change at ${changeAt} must not back it`)
  }
})

test("non-claims are ignored and claims are tracked independently", needsPatterns, () => {
  const t = tracker()
  assert.equal(t.addClaim(1, "What would you like?", 0), null)
  t.addClaim(2, "I'll add knots", 0)
  t.addClaim(3, "I've removed the fries", 50_000)
  t.recordCartChange(1_000)
  assert.deepEqual(t.resolve(9_000), [])
  assert.deepEqual(t.resolve(60_000), [{ id: 3, kind: "remove" }])
})

test("reset forgets everything", needsPatterns, () => {
  const t = tracker()
  t.recordCartChange(1)
  t.addClaim(1, "I'll add knots", 0)
  t.reset()
  assert.deepEqual(t.resolve(99_999), [])
})

test("tool call DOM ids match the server's ConsoleView.dom_token", () => {
  assert.equal(toolCallDomId("call_DeA64Ufy8pFTMgfLwZh4hQio"), "tool_call_call_DeA64Ufy8pFTMgfLwZh4hQio")
  assert.equal(toolCallDomId("a b/c.d"), "tool_call_a_b_c_d")
  assert.equal(toolCallDomId("x".repeat(200)).length, "tool_call_".length + 80)
})

// The "unbacked claim" heuristic, display only. A claim is an assistant line saying it changed the order ("I'll add garlic
// knots"). It is *unbacked* when no server event changed the cart version within [-before, +after] of the claim, measured
// on the browser's own receipt clock (server and browser clocks are never subtracted). Nothing here touches order state:
// it is evidence for a human to look at, and the server's order board stays the only truth.

export class ClaimTracker {
  // patterns: [{ kind, source }] from the server (ClaimDetector), compiled case-insensitively.
  constructor({ patterns = [], beforeMs = 2000, afterMs = 8000 } = {}) {
    this.patterns = patterns.map(({ kind, source }) => ({ kind, regexp: new RegExp(source, "i") }))
    this.beforeMs = beforeMs
    this.afterMs = afterMs
    this.cartChanges = []
    this.open = []
  }

  classify(text) {
    const hit = this.patterns.find(({ regexp }) => regexp.test(String(text || "")))
    return hit ? hit.kind : null
  }

  // A server event that changed cart_version was received by the browser at atMs.
  recordCartChange(atMs) {
    this.cartChanges.push(atMs)
  }

  // Registers an assistant line. Returns its claim kind, or null when it is not a claim.
  addClaim(id, text, atMs) {
    const kind = this.classify(text)
    if (kind) this.open.push({ id, kind, atMs })
    return kind
  }

  // Claims whose window has closed without a cart change; each is reported once. Backed claims are dropped silently.
  resolve(nowMs) {
    const unbacked = []
    this.open = this.open.filter((claim) => {
      if (nowMs < claim.atMs + this.afterMs) return true

      const backed = this.cartChanges.some((at) => at >= claim.atMs - this.beforeMs && at <= claim.atMs + this.afterMs)
      if (!backed) unbacked.push({ id: claim.id, kind: claim.kind })
      return false
    })
    return unbacked
  }

  reset() {
    this.cartChanges = []
    this.open = []
  }
}

// DOM id a server event row gets for a tool call id; must equal ConsoleView.dom_token on the server.
export function toolCallDomId(toolCallId) {
  return `tool_call_${String(toolCallId).replace(/[^\w-]/g, "_").slice(0, 80)}`
}

import { Controller } from "@hotwired/stimulus"
import { ClaimTracker, toolCallDomId } from "console/claims"

// Keeps the client's observations and the server's records side by side without ever merging them:
//  - a tool call the browser *saw announced* by Vapi becomes a "client observed" placeholder row; the server's own row
//    (same DOM id, from the ToolInvocation) replaces it, and if none arrives the row says so;
//  - it stamps observed latency (browser receipt of the server row minus receipt of Vapi's announcement);
//  - it remembers when server events that changed the cart version arrived, and flags assistant lines that claim a change
//    no server event backs (heuristic, display only);
//  - when the Action Cable stream (re)connects it reloads the persisted state from the database, so missed broadcasts
//    cannot leave the page wrong.
export default class extends Controller {
  static targets = ["cable"]
  static values = {
    claimPatterns: Array,
    responseTimeoutMs: { type: Number, default: 20000 }
  }

  connect() {
    this.pendingRows = new Map()
    this.highestVersion = -1
    this.tracker = new ClaimTracker({ patterns: this.claimPatternsValue })

    this.rows = new MutationObserver((records) => this.onRows(records))
    this.rows.observe(this.element, { childList: true, subtree: true })

    this.streams = new MutationObserver((records) => this.onStreams(records))
    this.streams.observe(this.element.ownerDocument.body, { attributes: true, attributeFilter: ["connected"], subtree: true })

    this.ticker = setInterval(() => this.resolveClaims(), 1000)
    this.showCable()
  }

  disconnect() {
    this.rows.disconnect()
    this.streams.disconnect()
    clearInterval(this.ticker)
    this.pendingRows.forEach(({ timer }) => clearTimeout(timer))
  }

  callStart() {
    this.tracker.reset()
    this.highestVersion = -1
  }

  // Vapi announced tool calls to this browser. Client observation only: the server's ToolInvocation is the proof.
  pending(event) {
    const events = this.element.querySelector("#events")
    if (!events) return

    for (const call of event.detail.calls || []) {
      const id = toolCallDomId(call.id)
      if (this.pendingRows.has(id) || this.element.querySelector(`#${CSS.escape(id)}`)) continue

      const row = document.createElement("div")
      row.id = id
      row.dataset.pending = "true"
      row.className = "grid grid-cols-[3rem_9rem_1fr] gap-2 border-t border-gray-800 px-4 py-1.5 text-xs text-gray-400"
      for (const text of ["⋯", call.name || "tool", "client observed · awaiting the server's record"]) {
        const cell = document.createElement("span")
        cell.textContent = text
        row.appendChild(cell)
      }
      events.appendChild(row)

      const timer = setTimeout(() => this.noServerResponse(id), this.responseTimeoutMsValue)
      this.pendingRows.set(id, { at: event.detail.at || Date.now(), timer })
    }
  }

  noServerResponse(id) {
    const row = this.element.querySelector(`#${CSS.escape(id)}[data-pending]`)
    if (!row) return
    row.lastElementChild.textContent = "⚠ no server record of this tool call was observed"
    row.className = row.className.replace("text-gray-400", "text-amber-400")
    row.dataset.noServer = "true"
  }

  transcriptFinal(event) {
    const { row, at } = event.detail
    if (row.role === "assistant") this.tracker.addClaim(row.id, row.text, at)
  }

  resolveClaims() {
    for (const claim of this.tracker.resolve(Date.now())) {
      this.dispatch("unbacked-claim", { detail: { rowId: claim.id, kind: claim.kind } })
    }
  }

  onRows(records) {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue
        const rows = node.matches("[data-server-row]") ? [node] : node.querySelectorAll("[data-server-row]")
        rows.forEach((row) => this.serverRow(row))
      }
    }
  }

  serverRow(row) {
    const pending = this.pendingRows.get(row.id)
    if (pending) {
      clearTimeout(pending.timer)
      this.pendingRows.delete(row.id)
      const cell = row.querySelector("[data-observed]")
      if (cell) cell.textContent = `${((Date.now() - pending.at) / 1000).toFixed(1)}s`
    }

    const version = Number(row.dataset.cartVersionAfter)
    if (Number.isFinite(version) && version > this.highestVersion) {
      const changed = row.dataset.cartChanged === "true"
      this.highestVersion = version
      if (changed) this.tracker.recordCartChange(Date.now())
    }
  }

  // Action Cable (re)connected: rebuild from the database so nothing broadcast while we were away is missing.
  onStreams(records) {
    this.showCable()
    if (records.some((r) => r.target.hasAttribute("connected"))) {
      this.element.querySelectorAll("turbo-frame[src]").forEach((frame) => frame.reload())
    }
  }

  showCable() {
    if (!this.hasCableTarget) return
    const connected = this.element.ownerDocument.querySelectorAll("turbo-cable-stream-source[connected]").length > 0
    this.cableTarget.textContent = connected ? "server link ● connected" : "server link ○ not connected"
    this.cableTarget.className = connected ? "text-emerald-400" : "text-gray-500"
  }
}

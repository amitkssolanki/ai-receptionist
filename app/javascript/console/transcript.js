// Pure transcript bookkeeping for the voice console (no DOM, no Vapi): turns Vapi's partial/final `transcript` client
// messages into rows, replacing a speaker's partial row in place by its final. This is Vapi's (non-authoritative)
// account of the conversation; nothing here knows anything about orders.

export const ROLE_LABELS = { user: "CUSTOMER", assistant: "AGENT" }

export function roleLabel(role) {
  return ROLE_LABELS[role] || "OTHER"
}

// "T+mm:ss" style offset from the start of the call.
export function formatOffset(ms) {
  const total = Math.max(0, Math.floor(ms / 1000))
  const minutes = String(Math.floor(total / 60)).padStart(2, "0")
  const seconds = String(total % 60).padStart(2, "0")
  return `${minutes}:${seconds}`
}

export class Transcript {
  constructor() {
    this.rows = []
    this.partialByRole = {}
    this.nextId = 1
  }

  // message: { role, transcriptType: "partial" | "final", transcript }; atMs: ms since the call started.
  // Returns { row, created } or null when the message carries no text.
  apply(message, atMs) {
    const text = (message && typeof message.transcript === "string" ? message.transcript : "").trim()
    if (!text) return null

    const role = message.role === "assistant" ? "assistant" : message.role === "user" ? "user" : "other"
    const isFinal = message.transcriptType === "final"
    const open = this.partialByRole[role]

    if (open) {
      open.text = text
      open.final = isFinal
      if (isFinal) delete this.partialByRole[role]
      return { row: open, created: false }
    }

    const row = { id: this.nextId++, role, text, final: isFinal, atMs }
    this.rows.push(row)
    if (!isFinal) this.partialByRole[role] = row
    return { row, created: true }
  }
}

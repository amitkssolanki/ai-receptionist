import { Controller } from "@hotwired/stimulus"
import { Transcript, formatOffset, roleLabel } from "console/transcript"

// Starts and stops a Vapi web call from the browser and renders Vapi's live conversation. Everything here is the
// *client's* view (source: VAPI): it is evidence of what was said, never of what the order system did. The order,
// the cart version and the tool executions come from the server panels, not from this controller.
//
// Only the restricted public key reaches this page. The signed console token is fetched fresh right before each
// call so the server can attach the call (and restaurant) to this console session.
export default class extends Controller {
  static targets = ["status", "elapsed", "start", "end", "mute", "agent", "level", "log", "banner", "emptyNote"]
  static values = {
    publicKey: String,
    assistantId: String,
    tokenUrl: String,
    sessionKey: String,
    clientMessages: Array
  }

  connect() {
    this.state = "idle"
    this.transcript = new Transcript()
    this.rowElements = new Map()
    this.startedAt = null
    this.render()

    this.beforeUnload = (event) => {
      if (this.live) { event.preventDefault(); event.returnValue = "" }
    }
    this.beforeVisit = (event) => {
      if (this.live && !window.confirm("A call is in progress. Leaving this page ends it. Leave?")) event.preventDefault()
    }
    window.addEventListener("beforeunload", this.beforeUnload)
    document.addEventListener("turbo:before-visit", this.beforeVisit)
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.beforeUnload)
    document.removeEventListener("turbo:before-visit", this.beforeVisit)
    this.stopTimer()
    if (this.vapi && this.live) this.vapi.stop()
  }

  get live() {
    return this.state === "connecting" || this.state === "live"
  }

  async start() {
    if (this.live) return

    this.hideBanner()
    this.transcript = new Transcript()
    this.rowElements = new Map()
    this.logTarget.replaceChildren()
    this.setState("connecting")

    try {
      const token = await this.fetchToken()
      // The vendored +esm build wraps the CommonJS module: the class is sdk.default.default (verified in a browser).
      const sdk = await import("@vapi-ai/web")
      const Vapi = sdk.default?.default || sdk.default
      this.vapi = new Vapi(this.publicKeyValue)
      this.bind(this.vapi)
      const call = await this.vapi.start(this.assistantIdValue, {
        clientMessages: this.clientMessagesValue,
        metadata: { console_token: token }
      })
      if (!call && this.state === "connecting") this.fail(new Error("Vapi did not start the call"))
    } catch (error) {
      this.fail(error)
    }
  }

  end() {
    if (this.vapi && this.live) this.vapi.stop()
  }

  toggleMute() {
    if (!this.vapi || !this.live) return
    this.vapi.setMuted(!this.vapi.isMuted())
    this.muteTarget.textContent = this.vapi.isMuted() ? "Unmute mic" : "Mute mic"
  }

  async fetchToken() {
    const response = await fetch(this.tokenUrlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content || "" },
      credentials: "same-origin",
      body: JSON.stringify({ session_key: this.sessionKeyValue })
    })
    if (!response.ok) throw new Error("Could not get a console token from the server")
    return (await response.json()).token
  }

  bind(vapi) {
    vapi.on("call-start", () => {
      this.startedAt = Date.now()
      this.setState("live")
      this.startTimer()
      this.dispatch("call-start", { detail: { sessionKey: this.sessionKeyValue, at: this.startedAt } })
    })
    vapi.on("call-end", () => this.finish("ended"))
    vapi.on("speech-start", () => this.setAgentSpeaking(true))
    vapi.on("speech-end", () => { this.setAgentSpeaking(false); this.setLevel(0) })
    vapi.on("volume-level", (level) => this.setLevel(level))
    vapi.on("message", (message) => this.onMessage(message))
    vapi.on("call-start-failed", (event) => this.fail(event))
    vapi.on("error", (event) => this.fail(event))
  }

  onMessage(message) {
    if (!message || typeof message !== "object") return
    const at = Date.now()

    switch (message.type) {
      case "transcript": {
        const result = this.transcript.apply(message, this.startedAt ? at - this.startedAt : 0)
        if (result) {
          this.renderRow(result.row)
          if (result.row.final) this.dispatch("transcript-final", { detail: { row: { ...result.row }, at } })
        }
        break
      }
      case "tool-calls":
        // The client *observed* Vapi asking for a tool. Only the server's ToolInvocation proves it ran.
        this.dispatch("tool-calls", { detail: { at, calls: (message.toolCallList || []).map((c) => ({ id: c.id, name: c.function?.name || c.name })) } })
        break
      case "user-interrupted":
        this.note("customer interrupted the agent")
        break
      case "hang":
        this.note("Vapi reports the agent stopped responding (hang)")
        break
    }
  }

  // --- rendering (DOM built with textContent only) ---

  renderRow(row) {
    let element = this.rowElements.get(row.id)
    if (!element) {
      element = document.createElement("div")
      element.dataset.rowId = row.id
      element.className = "grid grid-cols-[3.5rem_5rem_1fr] gap-2 py-0.5 text-sm"
      for (let i = 0; i < 3; i++) element.appendChild(document.createElement("span"))
      this.logTarget.appendChild(element)
      this.rowElements.set(row.id, element)
      if (this.hasEmptyNoteTarget) this.emptyNoteTarget.classList.add("hidden")
    }
    const [time, who, text] = element.children
    time.textContent = formatOffset(row.atMs)
    time.className = "text-gray-500"
    who.textContent = roleLabel(row.role)
    who.className = row.role === "assistant" ? "text-emerald-400" : "text-sky-400"
    text.textContent = row.text
    text.className = row.final ? "" : "italic text-gray-400"
    element.dataset.final = row.final
    this.logTarget.scrollTop = this.logTarget.scrollHeight
  }

  note(text) {
    const element = document.createElement("div")
    element.className = "py-0.5 text-xs text-gray-500"
    element.textContent = `— ${text} —`
    this.logTarget.appendChild(element)
  }

  setState(state) {
    this.state = state
    this.render()
  }

  render() {
    const labels = { idle: "READY", connecting: "◌ CONNECTING…", live: "● LIVE", ended: "ENDED", failed: "FAILED" }
    const colors = { idle: "text-gray-400", connecting: "text-amber-400", live: "text-emerald-400", ended: "text-gray-400", failed: "text-red-400" }
    this.statusTarget.textContent = labels[this.state]
    this.statusTarget.className = `font-semibold ${colors[this.state]}`
    this.startTarget.disabled = this.live
    this.endTarget.disabled = !this.live
    this.muteTarget.disabled = this.state !== "live"
    this.element.dataset.state = this.state
  }

  setAgentSpeaking(speaking) {
    this.agentTarget.textContent = speaking ? "agent speaking" : "agent listening"
    this.agentTarget.className = speaking ? "text-emerald-400" : "text-gray-500"
  }

  setLevel(level) {
    this.levelTarget.style.width = `${Math.round(Math.min(1, Math.max(0, Number(level) || 0)) * 100)}%`
  }

  startTimer() {
    this.stopTimer()
    this.timer = setInterval(() => {
      this.elapsedTarget.textContent = formatOffset(Date.now() - this.startedAt)
    }, 500)
  }

  stopTimer() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  finish(state) {
    this.stopTimer()
    this.setAgentSpeaking(false)
    this.setLevel(0)
    this.muteTarget.textContent = "Mute mic"
    if (this.state !== "failed") this.setState(state)
    this.dispatch("call-end", { detail: { at: Date.now() } })
  }

  fail(error) {
    if (this.state === "failed") return
    this.stopTimer()
    this.setState("failed")
    this.banner(this.describe(error))
    if (this.vapi) { try { this.vapi.stop() } catch (_) { /* already gone */ } }
    this.dispatch("call-end", { detail: { at: Date.now(), failed: true } })
  }

  // A short, safe description. Never the raw error object, never anything from the page's secrets.
  describe(error) {
    const text = String((error && (error.errorMsg || error.message || error.error?.message || error.type)) || "")
    if ((error && error.name === "NotAllowedError") || /permission|denied|not allowed/i.test(text)) {
      return "Microphone access was denied. Allow the microphone for this site and start again."
    }
    if (/console token/i.test(text)) return "The server could not issue a call token. Reload the page and sign in again if this continues."
    if (/key|auth|401|403|forbidden|unauthori[sz]ed|origin/i.test(text)) {
      return "Vapi rejected the browser key or this origin. Check the key's allowed origins and assistant restriction in the Vapi dashboard."
    }
    if (/did not start/i.test(text)) return "Vapi did not start the call."
    return `The call failed${text ? `: ${text.slice(0, 120)}` : "."}`
  }

  banner(text) {
    this.bannerTarget.textContent = text
    this.bannerTarget.classList.remove("hidden")
  }

  hideBanner() {
    this.bannerTarget.classList.add("hidden")
  }
}

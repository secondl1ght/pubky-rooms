// Chat composer: on a keyboard Enter sends and Shift+Enter inserts a newline;
// on a touch keyboard (phones: a coarse pointer) Enter inserts a newline and
// the button sends, as Signal, WhatsApp and Telegram do. The textarea grows
// with its content, the server can clear it after a send, and typing is
// reported (throttled here and again on the server; never stored).
const MAX_ROWS = 8
const TYPING_EVERY_MS = 2000

function touchKeyboard() {
  return typeof window.matchMedia === "function" && window.matchMedia("(pointer: coarse)").matches
}

const Composer = {
  mounted() {
    this.lastTyping = 0
    if (touchKeyboard()) this.el.setAttribute("enterkeyhint", "enter")
    this.el.addEventListener("keydown", e => {
      // Escape leaves an edit or a reply the way the Cancel button does
      if (e.key === "Escape" && document.querySelector("#composer-context")) {
        e.preventDefault()
        this.pushEvent("cancel_compose", {})
        return
      }
      if ((e.key === "Enter" || e.keyCode === 13) && !e.shiftKey && !e.isComposing && !touchKeyboard()) {
        e.preventDefault()
        if (this.el.value.trim() !== "") this.el.form.requestSubmit()
      }
    })
    this.el.addEventListener("input", () => {
      this.resize()
      this.reportTyping()
    })
    this.el.addEventListener("blur", () => this.stopTyping())
    this.handleEvent("composer:clear", () => {
      this.el.value = ""
      this.resize()
      this.el.focus()
    })
    this.handleEvent("composer:focus", () => this.el.focus())
    // editing: the server puts the message's text back into the box
    this.handleEvent("composer:set", ({value}) => {
      this.el.value = value
      this.resize()
      this.el.focus()
      this.el.setSelectionRange(this.el.value.length, this.el.value.length)
    })
    this.resize()
  },
  reportTyping() {
    if (this.el.value.trim() === "") return this.stopTyping()
    const now = Date.now()
    if (now - this.lastTyping >= TYPING_EVERY_MS) {
      this.lastTyping = now
      this.pushEvent("typing", {})
    }
  },
  stopTyping() {
    if (this.lastTyping === 0) return
    this.lastTyping = 0
    this.pushEvent("stop_typing", {})
  },
  resize() {
    const style = getComputedStyle(this.el)
    const line = parseFloat(style.lineHeight) || 24
    // vertical padding centres a single line against the avatar and button
    const padding = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0)
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, line * MAX_ROWS + padding) + "px"
  }
}

export default Composer

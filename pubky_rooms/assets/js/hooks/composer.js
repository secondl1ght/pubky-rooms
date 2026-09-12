// Chat composer: Enter sends (Shift+Enter inserts a newline), the textarea
// grows with its content, the server can clear it after a send, and typing
// is reported (throttled here and again on the server; never stored).
const MAX_ROWS = 8
const TYPING_EVERY_MS = 2000

const Composer = {
  mounted() {
    this.lastTyping = 0
    this.el.addEventListener("keydown", e => {
      if ((e.key === "Enter" || e.keyCode === 13) && !e.shiftKey && !e.isComposing) {
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
    const line = parseFloat(getComputedStyle(this.el).lineHeight) || 24
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, line * MAX_ROWS) + "px"
  }
}

export default Composer

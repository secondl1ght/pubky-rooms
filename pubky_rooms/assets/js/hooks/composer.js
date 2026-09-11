// Chat composer: Enter sends (Shift+Enter inserts a newline), the textarea
// grows with its content, and the server can clear it after a send.
const MAX_ROWS = 8

const Composer = {
  mounted() {
    this.el.addEventListener("keydown", e => {
      if ((e.key === "Enter" || e.keyCode === 13) && !e.shiftKey && !e.isComposing) {
        e.preventDefault()
        if (this.el.value.trim() !== "") this.el.form.requestSubmit()
      }
    })
    this.el.addEventListener("input", () => this.resize())
    this.handleEvent("composer:clear", () => {
      this.el.value = ""
      this.resize()
      this.el.focus()
    })
    this.resize()
  },
  resize() {
    const line = parseFloat(getComputedStyle(this.el).lineHeight) || 24
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, line * MAX_ROWS) + "px"
  }
}

export default Composer

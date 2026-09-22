// Dismisses a flash toast after `data-dismiss-after` milliseconds (default 5 s)
// by triggering its own click handler, which clears the flash and hides it.
// The timer pauses while the toast is hovered or holds focus, and re-arms
// whenever the toast re-renders with a new message.
const AutoDismiss = {
  mounted() {
    this.el.addEventListener("mouseenter", () => this.disarm())
    this.el.addEventListener("mouseleave", () => this.arm())
    this.el.addEventListener("focusin", () => this.disarm())
    this.el.addEventListener("focusout", () => this.arm())
    this.arm()
  },
  updated() {
    this.arm()
  },
  arm() {
    this.disarm()
    const ms = parseInt(this.el.dataset.dismissAfter || "5000", 10)
    this.timer = setTimeout(() => this.el.click(), ms)
  },
  disarm() {
    clearTimeout(this.timer)
  },
  destroyed() {
    this.disarm()
  }
}

export default AutoDismiss

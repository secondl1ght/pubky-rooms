// Copies `data-copy` to the clipboard on click and briefly confirms it: a
// text button swaps its label, an icon button with a `data-tip` tooltip swaps
// the tooltip text and shows a check mark instead.
const Clipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const text = this.el.dataset.copy
      if (!text) return
      try {
        await navigator.clipboard.writeText(text)
        this.flash("Copied", "lucide-check")
      } catch (_err) {
        this.flash("Copy failed", "lucide-x")
      }
    })
  },
  flash(label, icon) {
    const el = this.el
    const original = el.innerHTML
    const originalTip = el.dataset.tip
    if (originalTip !== undefined) {
      el.dataset.tip = label
      el.innerHTML = `<span class="${icon} size-4" aria-hidden="true"></span>\`
    } else {
      el.innerHTML = label
    }
    el.setAttribute("aria-live", "polite")
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      el.innerHTML = original
      if (originalTip !== undefined) el.dataset.tip = originalTip
    }, 1500)
  },
  destroyed() {
    clearTimeout(this.timer)
  }
}

export default Clipboard

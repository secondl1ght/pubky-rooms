// Copies `data-copy` to the clipboard on click and briefly confirms it.
const Clipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const text = this.el.dataset.copy
      if (!text) return
      try {
        await navigator.clipboard.writeText(text)
        this.flash("Copied")
      } catch (_err) {
        this.flash("Copy failed")
      }
    })
  },
  flash(label) {
    const original = this.el.innerHTML
    this.el.innerHTML = label
    this.el.setAttribute("aria-live", "polite")
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.el.innerHTML = original
    }, 1500)
  },
  destroyed() {
    clearTimeout(this.timer)
  }
}

export default Clipboard

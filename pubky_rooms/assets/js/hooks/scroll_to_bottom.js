// Keeps a chat list pinned to the bottom while the reader is near it, and
// preserves the scroll offset when older messages are prepended.
const THRESHOLD = 80

const ScrollToBottom = {
  mounted() {
    this.pinned = true
    this.el.addEventListener("scroll", () => {
      this.pinned = this.distanceFromBottom() < THRESHOLD
    })
    this.observer = new MutationObserver(() => this.afterUpdate())
    this.observer.observe(this.el, {childList: true, subtree: true})
    this.scrollToBottom()
  },
  beforeUpdate() {
    this.prevHeight = this.el.scrollHeight
    this.prevTop = this.el.scrollTop
  },
  afterUpdate() {
    if (this.pinned) {
      this.scrollToBottom()
    } else if (this.el.dataset.prepending === "true") {
      this.el.scrollTop = this.prevTop + (this.el.scrollHeight - this.prevHeight)
    }
  },
  updated() {
    this.afterUpdate()
  },
  distanceFromBottom() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
  destroyed() {
    this.observer && this.observer.disconnect()
  }
}

export default ScrollToBottom

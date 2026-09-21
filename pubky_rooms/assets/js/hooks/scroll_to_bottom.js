// Keeps a chat list pinned to the bottom while the reader is near it, asks
// the server for earlier messages when the reader nears the top (the list
// element carries data-has-more), and preserves the scroll offset when those
// are prepended.
const BOTTOM_THRESHOLD = 80
const TOP_THRESHOLD = 240

const ScrollToBottom = {
  mounted() {
    this.pinned = true
    this.loadingOlder = false
    this.el.addEventListener("scroll", () => {
      this.pinned = this.distanceFromBottom() < BOTTOM_THRESHOLD
      this.maybeLoadOlder()
    })
    this.handleEvent("older:loaded", ({count}) => {
      this.loadingOlder = false
      // still at the top with more to load (short pages): keep going — but an
      // empty page (a member's homeserver is down) waits for the reader to
      // scroll or press the button, so we never hammer a dead homeserver
      if (count > 0) this.maybeLoadOlder()
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
    if (this.loadingOlder && this.el.scrollHeight > this.prevHeight) {
      // earlier messages arrived above: keep what the reader was looking at in place
      this.el.scrollTop = this.prevTop + (this.el.scrollHeight - this.prevHeight)
      this.prevHeight = this.el.scrollHeight
      this.prevTop = this.el.scrollTop
    } else if (this.pinned) {
      this.scrollToBottom()
    }
  },
  updated() {
    this.afterUpdate()
  },
  maybeLoadOlder() {
    if (this.loadingOlder || this.el.dataset.hasMore !== "true") return
    if (this.el.scrollTop < TOP_THRESHOLD && this.el.scrollHeight > this.el.clientHeight) {
      this.loadingOlder = true
      this.pushEvent("load_older", {})
    }
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

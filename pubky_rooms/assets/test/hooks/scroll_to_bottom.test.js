import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"
import ScrollToBottom from "../../js/hooks/scroll_to_bottom"
import {mountHook} from "../support/hook"

// jsdom has no layout: give the list explicit scroll metrics.
function defineScroll(el, {scrollHeight, clientHeight}) {
  const metrics = {scrollHeight, clientHeight, scrollTop: 0}
  for (const key of ["scrollHeight", "clientHeight"]) {
    Object.defineProperty(el, key, {get: () => metrics[key], configurable: true})
  }
  Object.defineProperty(el, "scrollTop", {
    get: () => metrics.scrollTop,
    set: (v) => {
      metrics.scrollTop = Math.max(0, Math.min(v, metrics.scrollHeight - metrics.clientHeight))
    },
    configurable: true
  })
  return metrics
}

const list = (hasMore) =>
  `<div id="messages" phx-hook="ScrollToBottom" data-has-more="${hasMore}"><div id="msg-1">one</div></div>`

describe("ScrollToBottom", () => {
  let mounted, el, metrics

  const mount = (hasMore = "false", {scrollHeight = 2000, clientHeight = 600} = {}) => {
    // metrics must exist before mounted() scrolls to the bottom
    const wrapper = document.createElement("div")
    wrapper.innerHTML = list(hasMore)
    const target = wrapper.firstElementChild
    metrics = defineScroll(target, {scrollHeight, clientHeight})
    mounted = mountHook(ScrollToBottom, wrapper.innerHTML)
    // mountHook parsed fresh HTML; move the metrics onto the mounted element
    metrics = defineScroll(mounted.el, {scrollHeight, clientHeight})
    mounted.hook.scrollToBottom()
    el = mounted.el
    return mounted
  }

  const scrollTo = (top) => {
    el.scrollTop = top
    el.dispatchEvent(new Event("scroll"))
  }

  afterEach(() => mounted && mounted.unmount())

  it("starts at the bottom and follows new rows while the reader stays near the bottom", () => {
    mount()
    expect(el.scrollTop).toBe(1400)
    metrics.scrollHeight = 2300
    mounted.update()
    expect(el.scrollTop).toBe(1700)
  })

  it("leaves the reader alone once they scroll away, and pins again when they come back", () => {
    mount()
    scrollTo(200)
    metrics.scrollHeight = 2300
    mounted.update()
    expect(el.scrollTop).toBe(200)

    scrollTo(1650) // within 80 px of the bottom
    metrics.scrollHeight = 2600
    mounted.update()
    expect(el.scrollTop).toBe(2000)
  })

  it("asks for older messages once near the top, only when the list says there are more", () => {
    mount("false")
    scrollTo(100)
    expect(mounted.pushes).toEqual([])

    el.dataset.hasMore = "true"
    scrollTo(90)
    scrollTo(80)
    expect(mounted.pushes.map((p) => p.event)).toEqual(["load_older"])
  })

  it("keeps the reader's place when older rows are prepended, then keeps paging short pages but not empty ones", () => {
    mount("true")
    scrollTo(100)
    expect(mounted.pushes.length).toBe(1)

    mounted.update(() => {
      metrics.scrollHeight = 2800 // 800 px of older rows above
    })
    expect(el.scrollTop).toBe(900)

    // still near the top? no (900 px), so a non-empty page does not chain a request
    mounted.fire("older:loaded", {count: 20})
    expect(mounted.pushes.length).toBe(1)

    scrollTo(50)
    expect(mounted.pushes.length).toBe(2)
    mounted.fire("older:loaded", {count: 3}) // a short page while still at the top: keep going
    expect(mounted.pushes.length).toBe(3)
    mounted.fire("older:loaded", {count: 0}) // an empty page waits for the reader
    expect(mounted.pushes.length).toBe(3)
    scrollTo(40)
    expect(mounted.pushes.length).toBe(4)
  })

  it("does not page a list that fits without scrolling", () => {
    mount("true", {scrollHeight: 300, clientHeight: 600})
    scrollTo(0)
    expect(mounted.pushes).toEqual([])
  })

  it("scrolls a quoted message into view, flashes it and unpins", () => {
    vi.useFakeTimers()
    mount()
    const target = el.querySelector("#msg-1")
    target.scrollIntoView = vi.fn()
    mounted.fire("scroll_to", {id: "msg-1"})
    expect(target.scrollIntoView).toHaveBeenCalledWith({block: "center"})
    expect(target.classList.contains("jump-highlight")).toBe(true)
    vi.advanceTimersByTime(1600)
    expect(target.classList.contains("jump-highlight")).toBe(false)

    metrics.scrollHeight = 2300
    mounted.update()
    expect(el.scrollTop).toBe(1400) // not dragged back to the bottom
    mounted.fire("scroll_to", {id: "missing"}) // unknown ids are ignored
    vi.useRealTimers()
  })
})

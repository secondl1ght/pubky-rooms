import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"
import AutoDismiss from "../../js/hooks/auto_dismiss"
import {mountHook} from "../support/hook"

const toast = (ms) =>
  `<div id="flash" phx-hook="AutoDismiss"${ms ? ` data-dismiss-after="${ms}"` : ""}>Saved</div>`

describe("AutoDismiss", () => {
  let mounted, clicks

  beforeEach(() => {
    vi.useFakeTimers()
    clicks = 0
  })

  afterEach(() => {
    mounted && mounted.unmount()
    vi.useRealTimers()
  })

  const mount = (html) => {
    mounted = mountHook(AutoDismiss, html)
    mounted.el.addEventListener("click", () => clicks++)
    return mounted
  }

  it("clicks itself after data-dismiss-after milliseconds", () => {
    mount(toast(1000))
    vi.advanceTimersByTime(999)
    expect(clicks).toBe(0)
    vi.advanceTimersByTime(1)
    expect(clicks).toBe(1)
  })

  it("defaults to five seconds", () => {
    mount(toast())
    vi.advanceTimersByTime(4999)
    expect(clicks).toBe(0)
    vi.advanceTimersByTime(1)
    expect(clicks).toBe(1)
  })

  it("pauses while hovered or focused and restarts the full delay afterwards", () => {
    const {el} = mount(toast(1000))
    vi.advanceTimersByTime(900)
    el.dispatchEvent(new Event("mouseenter"))
    vi.advanceTimersByTime(5000)
    expect(clicks).toBe(0)
    el.dispatchEvent(new Event("mouseleave"))
    vi.advanceTimersByTime(999)
    expect(clicks).toBe(0)
    vi.advanceTimersByTime(1)
    expect(clicks).toBe(1)

    el.dispatchEvent(new Event("focusin"))
    vi.advanceTimersByTime(5000)
    expect(clicks).toBe(1)
    el.dispatchEvent(new Event("focusout"))
    vi.advanceTimersByTime(1000)
    expect(clicks).toBe(2)
  })

  it("re-arms when the toast re-renders and stops when destroyed", () => {
    const {hook} = mount(toast(1000))
    vi.advanceTimersByTime(800)
    hook.updated()
    vi.advanceTimersByTime(800)
    expect(clicks).toBe(0)
    vi.advanceTimersByTime(200)
    expect(clicks).toBe(1)

    hook.updated()
    hook.destroyed()
    vi.advanceTimersByTime(5000)
    expect(clicks).toBe(1)
  })
})

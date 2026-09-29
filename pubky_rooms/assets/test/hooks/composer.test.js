import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"
import Composer from "../../js/hooks/composer"
import {input, keydown, mountHook} from "../support/hook"

const html = `<form id="f"><textarea id="composer" phx-hook="Composer"></textarea></form>`

describe("Composer", () => {
  let mounted, el, form

  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-09-28T12:00:00Z"))
    mounted = mountHook(Composer, html, {select: "textarea"})
    el = mounted.el
    form = el.form
    form.requestSubmit = vi.fn()
  })

  afterEach(() => {
    mounted.unmount()
    vi.useRealTimers()
  })

  it("Enter submits the form when there is text; Shift+Enter and composition do not", () => {
    input(el, "hello")
    const enter = keydown(el, "Enter")
    expect(enter.defaultPrevented).toBe(true)
    expect(form.requestSubmit).toHaveBeenCalledTimes(1)

    keydown(el, "Enter", {shiftKey: true})
    keydown(el, "Enter", {isComposing: true})
    expect(form.requestSubmit).toHaveBeenCalledTimes(1)
  })

  it("Enter on a blank message sends nothing but still swallows the newline", () => {
    input(el, "   ")
    const enter = keydown(el, "Enter")
    expect(enter.defaultPrevented).toBe(true)
    expect(form.requestSubmit).not.toHaveBeenCalled()
  })

  it("grows with its content and caps at eight rows plus its own padding", () => {
    el.style.lineHeight = "24px"
    el.style.paddingTop = "8px"
    el.style.paddingBottom = "8px"
    Object.defineProperty(el, "scrollHeight", {configurable: true, get: () => 100})
    input(el, "a\nb\nc")
    expect(el.style.height).toBe("100px")
    Object.defineProperty(el, "scrollHeight", {configurable: true, get: () => 5000})
    input(el, "many\nmore\nlines")
    expect(el.style.height).toBe("208px")
  })

  it("reports typing at most every two seconds and stop_typing on blur or when emptied", () => {
    input(el, "h")
    input(el, "he")
    expect(mounted.pushes.map((p) => p.event)).toEqual(["typing"])

    vi.setSystemTime(new Date("2026-09-28T12:00:02Z"))
    input(el, "hel")
    expect(mounted.pushes.map((p) => p.event)).toEqual(["typing", "typing"])

    el.dispatchEvent(new Event("blur"))
    expect(mounted.pushes.map((p) => p.event)).toEqual(["typing", "typing", "stop_typing"])
    // idle: a second blur pushes nothing more
    el.dispatchEvent(new Event("blur"))
    expect(mounted.pushes.length).toBe(3)

    vi.setSystemTime(new Date("2026-09-28T12:00:10Z"))
    input(el, "x")
    input(el, "")
    expect(mounted.pushes.map((p) => p.event).slice(3)).toEqual(["typing", "stop_typing"])
  })

  it("the server can clear, focus and preset the text (editing)", () => {
    input(el, "draft")
    mounted.fire("composer:clear")
    expect(el.value).toBe("")
    expect(document.activeElement).toBe(el)

    el.blur()
    mounted.fire("composer:set", {value: "edited text"})
    expect(el.value).toBe("edited text")
    expect(document.activeElement).toBe(el)
    expect(el.selectionStart).toBe("edited text".length)

    el.blur()
    mounted.fire("composer:focus")
    expect(document.activeElement).toBe(el)
  })

  it("grows with its content up to eight lines", () => {
    Object.defineProperty(el, "scrollHeight", {value: 500, configurable: true})
    input(el, "many\nlines")
    // jsdom has no line-height, so the hook falls back to 24 px: 8 lines = 192 px
    expect(el.style.height).toBe("192px")

    Object.defineProperty(el, "scrollHeight", {value: 60, configurable: true})
    input(el, "two\nlines")
    expect(el.style.height).toBe("60px")
  })
})

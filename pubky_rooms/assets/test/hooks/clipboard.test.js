import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"
import Clipboard from "../../js/hooks/clipboard"
import {mountHook} from "../support/hook"

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe("Clipboard", () => {
  let mounted, writeText

  beforeEach(() => {
    writeText = vi.fn(() => Promise.resolve())
    Object.defineProperty(navigator, "clipboard", {value: {writeText}, configurable: true})
  })

  afterEach(() => mounted && mounted.unmount())

  it("copies data-copy and swaps a text button's label for 1.5 s", async () => {
    vi.useFakeTimers({shouldAdvanceTime: true})
    mounted = mountHook(Clipboard, `<button id="c" phx-hook="Clipboard" data-copy="pubky://abc">Copy link</button>`)
    const {el} = mounted
    el.click()
    await flush()
    expect(writeText).toHaveBeenCalledWith("pubky://abc")
    expect(el.innerHTML).toBe("Copied")
    expect(el.getAttribute("aria-live")).toBe("polite")
    vi.advanceTimersByTime(1500)
    expect(el.innerHTML).toBe("Copy link")
    vi.useRealTimers()
  })

  it("an icon button with a tooltip swaps the tooltip text and shows a check mark", async () => {
    vi.useFakeTimers({shouldAdvanceTime: true})
    mounted = mountHook(
      Clipboard,
      `<button id="c" phx-hook="Clipboard" data-copy="k" data-tip="Copy key"><span class="lucide-copy size-4"></span></button>`
    )
    const {el} = mounted
    el.click()
    await flush()
    expect(el.dataset.tip).toBe("Copied")
    expect(el.querySelector("span").className).toContain("lucide-check")
    vi.advanceTimersByTime(1500)
    expect(el.dataset.tip).toBe("Copy key")
    expect(el.querySelector("span").className).toContain("lucide-copy")
    vi.useRealTimers()
  })

  it("reports a failed copy instead of pretending", async () => {
    writeText.mockImplementation(() => Promise.reject(new Error("denied")))
    mounted = mountHook(Clipboard, `<button id="c" phx-hook="Clipboard" data-copy="k" data-tip="Copy key"><span class="lucide-copy"></span></button>`)
    mounted.el.click()
    await flush()
    expect(mounted.el.dataset.tip).toBe("Copy failed")
    expect(mounted.el.querySelector("span").className).toContain("lucide-x")
  })

  it("does nothing without data-copy", async () => {
    mounted = mountHook(Clipboard, `<button id="c" phx-hook="Clipboard">Copy</button>`)
    mounted.el.click()
    await flush()
    expect(writeText).not.toHaveBeenCalled()
    expect(mounted.el.innerHTML).toBe("Copy")
  })
})

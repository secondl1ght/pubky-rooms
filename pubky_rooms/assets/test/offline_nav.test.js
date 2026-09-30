import {afterEach, beforeAll, beforeEach, describe, expect, it, vi} from "vitest"
import {installOfflineNavigation} from "../js/offline_nav"

// one listener for the whole file (the real app installs it once per page)
describe("offline navigation", () => {
  let offline, navigate, reload, link, other

  beforeAll(() => {
    installOfflineNavigation({
      isOffline: () => offline,
      navigate: (href) => navigate(href),
      reload: () => reload()
    })
  })

  beforeEach(() => {
    offline = false
    navigate = vi.fn()
    reload = vi.fn()
    document.body.innerHTML =
      '<a id="live" href="/rooms/x" data-phx-link="redirect">room</a><a id="plain" href="/about">about</a>'
    link = document.getElementById("live")
    other = document.getElementById("plain")
  })

  afterEach(() => {
    document.body.innerHTML = ""
  })

  const click = (el, opts = {}) => {
    const e = new MouseEvent("click", {bubbles: true, cancelable: true, button: 0, ...opts})
    el.dispatchEvent(e)
    return e
  }

  it("online: LiveView keeps its links and history", () => {
    expect(click(link).defaultPrevented).toBe(false)
    expect(navigate).not.toHaveBeenCalled()
    window.dispatchEvent(new PopStateEvent("popstate"))
    expect(reload).not.toHaveBeenCalled()
  })

  it("offline: a live link becomes a full navigation, other links and modified clicks are untouched, back reloads", () => {
    offline = true
    expect(click(link).defaultPrevented).toBe(true)
    expect(navigate).toHaveBeenCalledWith(link.href)
    expect(click(other).defaultPrevented).toBe(false)
    click(link, {metaKey: true})
    expect(navigate).toHaveBeenCalledTimes(1)
    window.dispatchEvent(new PopStateEvent("popstate"))
    expect(reload).toHaveBeenCalledTimes(1)
  })
})

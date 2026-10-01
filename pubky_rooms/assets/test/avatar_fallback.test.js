import {beforeAll, beforeEach, describe, expect, it} from "vitest"
import {installAvatarFallback} from "../js/avatar_fallback"

describe("avatar fallback", () => {
  beforeAll(() => installAvatarFallback(document))

  beforeEach(() => {
    document.body.innerHTML =
      '<span id="a"><span id="initial">S</span><img id="pic" data-avatar src="https://x/a.png"></span>' +
      '<img id="other" src="https://x/b.png">'
  })

  it("removes an avatar image that fails to load, leaving the fallback", () => {
    document.getElementById("pic").dispatchEvent(new Event("error"))
    expect(document.getElementById("pic")).toBeNull()
    expect(document.getElementById("initial")).not.toBeNull()
  })

  it("leaves other images alone", () => {
    document.getElementById("other").dispatchEvent(new Event("error"))
    expect(document.getElementById("other")).not.toBeNull()
  })
})

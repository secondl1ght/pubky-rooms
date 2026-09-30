import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"
import TagInput from "../../js/hooks/tag_input"
import {input, keydown, mountHook} from "../support/hook"

// Mirrors PubkyRoomsWeb.UI.TagInput's markup (the Elixir component test pins
// the attributes the hook relies on: data-tag-input, data-role, ids, data-*).
function markup({labels = [], fixed = [], max = 4, suggestions = []} = {}) {
  const chip = (l) =>
    `<span data-label="${l}"><span>${l}</span><button type="button" aria-label="Remove ${l}"></button></span>`
  const fixedChip = (l) => `<span data-fixed="${l}"><span>${l}</span></span>`
  const option = (l) => `<li><button type="button" data-role="suggestion" data-label="${l}">${l}</button></li>`
  return `
    <div id="t" data-tag-input>
      <input type="hidden" name="room[tags]" value="${labels.join(" ")}">
      ${fixed.map(fixedChip).join("")}
      ${labels.map(chip).join("")}
      <div id="t-control" data-role="control" phx-hook="TagInput" data-on-add="add_tag"
           data-on-remove="remove_tag" data-on-query="tag_query" data-count="${labels.length}" data-max="${max}">
        <button type="button" data-role="add">+</button>
        <div data-role="field" hidden>
          <input id="t-input" type="text" maxlength="20" placeholder="add tag" data-placeholder="add tag">
          <button type="button" data-role="close">x</button>
        </div>
        ${suggestions.length ? `<ul data-role="suggestions">${suggestions.map(option).join("")}</ul>` : ""}
      </div>
    </div>`
}

describe("TagInput", () => {
  let mounted, el, field, textInput

  const mount = (opts) => {
    mounted = mountHook(TagInput, markup(opts), {select: "#t-control"})
    el = mounted.el
    field = el.querySelector("[data-role=field]")
    textInput = el.querySelector("#t-input")
    return mounted
  }
  const open = () => el.querySelector("[data-role=add]").click()
  const events = () => mounted.pushes.map((p) => p.event)

  beforeEach(() => vi.useFakeTimers())
  afterEach(() => {
    mounted && mounted.unmount()
    vi.useRealTimers()
  })

  it("the hook element holds the control only, never the chips (they must stay outside its lock)", () => {
    mount({labels: ["a", "b"], fixed: ["room"]})
    expect(el.querySelector("[data-label]")).toBeNull()
    expect(el.querySelector("[data-fixed]")).toBeNull()
    expect(mounted.hook.root.querySelectorAll("[data-label]").length).toBe(2)
  })

  it("+ opens and focuses the field, x folds it and clears it", () => {
    mount()
    expect(field.hidden).toBe(true)
    open()
    expect(field.hidden).toBe(false)
    expect(el.querySelector("[data-role=add]").hidden).toBe(true)
    expect(document.activeElement).toBe(textInput)

    input(textInput, "abc")
    el.querySelector("[data-role=close]").click()
    expect(field.hidden).toBe(true)
    expect(textInput.value).toBe("")
    expect(events()).toEqual(["tag_query"]) // the fold resets the suggestions
    expect(mounted.pushes[0].payload).toEqual({q: ""})
  })

  it("pushes nothing after the view is destroyed (the field blurs when the dialog is torn down)", () => {
    mount()
    open()
    input(textInput, "bitcoin")
    mounted.hook.destroyed()
    // LiveView removes the DOM after destroyed(): the focused field blurs
    textInput.dispatchEvent(new Event("blur"))
    vi.advanceTimersByTime(1000)
    expect(events()).toEqual([])
  })

  it("lowercases, strips commas, colons and whitespace, cuts at 20 characters, and queries after a pause", () => {
    mount()
    open()
    input(textInput, "Bit Coin,X:Y\tz")
    expect(textInput.value).toBe("bitcoinxyz")
    expect(events()).toEqual([])
    vi.advanceTimersByTime(120)
    expect(mounted.pushes).toEqual([{event: "tag_query", payload: {q: "bitcoinxyz"}}])

    input(textInput, "a".repeat(25))
    expect(textInput.value).toBe("a".repeat(20))
    input(textInput, "🔥🔥🔥") // characters, not bytes
    expect(textInput.value).toBe("🔥🔥🔥")
  })

  it("Enter adds the typed label and clears the field; an empty Enter adds nothing", () => {
    mount()
    open()
    keydown(textInput, "Enter")
    expect(events()).toEqual([])
    input(textInput, "nostr")
    const enter = keydown(textInput, "Enter")
    expect(enter.defaultPrevented).toBe(true)
    expect(mounted.pushes).toEqual([{event: "add_tag", payload: {label: "nostr"}}])
    expect(textInput.value).toBe("")
    vi.advanceTimersByTime(200)
    expect(events()).toEqual(["add_tag"]) // the pending query was cancelled by the add
  })

  it("arrow keys highlight a suggestion and Enter picks it; clicking one does not blur the field first", () => {
    mount({suggestions: ["bitcoin", "bitkit"]})
    open()
    input(textInput, "bit")
    const options = el.querySelectorAll("[data-role=suggestion]")
    keydown(textInput, "ArrowDown")
    expect(options[0].getAttribute("aria-selected")).toBe("true")
    keydown(textInput, "ArrowUp") // wraps to the last
    expect(options[1].getAttribute("aria-selected")).toBe("true")
    expect(options[0].getAttribute("aria-selected")).toBe("false")
    keydown(textInput, "Enter")
    expect(mounted.pushes.filter((p) => p.event === "add_tag")).toEqual([{event: "add_tag", payload: {label: "bitkit"}}])

    const mousedown = new MouseEvent("mousedown", {bubbles: true, cancelable: true})
    options[0].dispatchEvent(mousedown)
    expect(mousedown.defaultPrevented).toBe(true)
  })

  it("Backspace on an empty field removes the last chip, never a fixed one", () => {
    mount({labels: ["a", "b"], fixed: ["room"]})
    open()
    input(textInput, "x")
    keydown(textInput, "Backspace")
    expect(events()).toEqual([]) // text present: normal backspace
    input(textInput, "")
    const bs = keydown(textInput, "Backspace")
    expect(bs.defaultPrevented).toBe(true)
    expect(mounted.pushes.filter((p) => p.event === "remove_tag")).toEqual([{event: "remove_tag", payload: {label: "b"}}])
    mounted.unmount()

    mount({labels: [], fixed: ["room"]})
    open()
    keydown(textInput, "Backspace")
    expect(events()).toEqual([])
  })

  it("Escape clears the text first and folds on the second press", () => {
    mount()
    open()
    input(textInput, "abc")
    keydown(textInput, "Escape")
    expect(textInput.value).toBe("")
    expect(field.hidden).toBe(false)
    keydown(textInput, "Escape")
    expect(field.hidden).toBe(true)
  })

  it("Escape never reaches the window (a dialog around the field would close on it)", () => {
    mount()
    open()
    const onWindow = vi.fn()
    window.addEventListener("keydown", onWindow)
    input(textInput, "abc")
    keydown(textInput, "Escape")
    keydown(textInput, "Escape")
    keydown(textInput, "a")
    window.removeEventListener("keydown", onWindow)
    expect(onWindow).toHaveBeenCalledTimes(1)
    expect(onWindow.mock.calls[0][0].key).toBe("a")
  })

  it("leaving an empty field folds it after a moment; leaving typed text keeps it open", () => {
    mount()
    open()
    textInput.blur()
    vi.advanceTimersByTime(200)
    expect(field.hidden).toBe(true)

    open()
    input(textInput, "draft")
    textInput.blur()
    vi.advanceTimersByTime(200)
    expect(field.hidden).toBe(false)
  })

  it("at the limit the field is read-only, stays open and reads 'limit reached'; it reopens when a chip goes", () => {
    mount({labels: ["a", "b", "c"], max: 4})
    open()
    input(textInput, "d")
    keydown(textInput, "Enter")
    expect(mounted.pushes.at(-1)).toEqual({event: "add_tag", payload: {label: "d"}})

    // the server re-renders with four chips: the control's data-count changes
    mounted.update(() => {
      el.dataset.count = "4"
      el.querySelector("[data-role=add]").disabled = true
    })
    expect(field.hidden).toBe(false)
    expect(textInput.readOnly).toBe(true)
    expect(textInput.disabled).toBe(false)
    expect(textInput.placeholder).toBe("limit reached")
    expect(textInput.classList.contains("at-limit")).toBe(true)
    expect(document.activeElement).toBe(textInput) // disabling would have blurred and folded it

    keydown(textInput, "Backspace")
    expect(mounted.pushes.at(-1).event).toBe("remove_tag")
    mounted.update(() => {
      el.dataset.count = "3"
    })
    expect(textInput.readOnly).toBe(false)
    expect(textInput.placeholder).toBe("add tag")
    expect(textInput.classList.contains("at-limit")).toBe(false)
  })

  it("survives a re-render while open: the field stays open and focused", () => {
    mount()
    open()
    textInput.blur()
    mounted.update()
    expect(field.hidden).toBe(false)
    expect(document.activeElement).toBe(textInput)
  })
})

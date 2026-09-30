// Drives `<.tag_input>` (PubkyRoomsWeb.UI.TagInput) the way Pubky App's tag
// input behaves. The labels themselves live in the LiveView; this hook only
// owns the field: open/closed, live sanitising, keyboard, suggestion
// selection, and pushes the events named in its element's data attributes.
//
// The hook element is the "+"/field control, not the whole input: LiveView
// locks a hook's element from pushEvent until the reply, and with two adds
// in flight the chips inside a locked container went missing (the second
// reply's skip placeholders found no node to keep). The chips live in the
// enclosing `[data-tag-input]`, outside the lock.
//
// Banned characters mirror pubky-app-specs `tagInvalidChars` (comma, colon,
// whitespace) and `PubkyRooms.Tags.Tag.banned_chars/0`; keep them in sync.
const BANNED = /[,:\s]/g
const MAX_LENGTH = 20
const QUERY_DEBOUNCE_MS = 120
const BLUR_DELAY_MS = 200

const TagInput = {
  mounted() {
    this.open = false
    this.selected = -1
    this.root = this.el.closest("[data-tag-input]") || this.el
    this.input = this.el.querySelector("input[type=text]")
    if (!this.input) return

    this.el.addEventListener("click", (e) => {
      if (e.target.closest("[data-role=add]")) {
        e.preventDefault()
        this.setOpen(true)
      } else if (e.target.closest("[data-role=close]")) {
        e.preventDefault()
        this.setOpen(false)
      }
    })
    // Clicking a suggestion must not blur the field first.
    this.el.addEventListener("mousedown", (e) => {
      if (e.target.closest("[data-role=suggestions]")) e.preventDefault()
    })
    this.input.addEventListener("input", () => this.onInput())
    this.input.addEventListener("keydown", (e) => this.onKey(e))
    this.input.addEventListener("blur", () => {
      // the field blurs when its LiveView is torn down (navigating to the new
      // room): nothing to fold or query any more
      if (this.gone) return
      this.blurTimer = setTimeout(() => this.onBlur(), BLUR_DELAY_MS)
    })
    this.apply()
  },

  // The server re-renders the chips and the "+"/field wrappers on every
  // change; reapply the client-side open state and limit afterwards. At the
  // limit the field is read-only, not disabled: disabling a focused input
  // blurs it, which folded the field before "limit reached" could be read.
  updated() {
    this.apply()
  },

  destroyed() {
    this.gone = true
    clearTimeout(this.queryTimer)
    clearTimeout(this.blurTimer)
  },

  setOpen(open) {
    this.open = open
    if (!open) {
      this.input.value = ""
      this.query("")
    }
    this.apply()
    if (open) this.input.focus()
  },

  apply() {
    const add = this.el.querySelector("[data-role=add]")
    const field = this.el.querySelector("[data-role=field]")
    if (!add || !field) return
    const count = parseInt(this.el.dataset.count || "0", 10)
    const max = this.el.dataset.max ? parseInt(this.el.dataset.max, 10) : Infinity
    const atLimit = count >= max
    add.hidden = this.open
    field.hidden = !this.open
    this.input.readOnly = atLimit
    this.input.placeholder = atLimit ? "limit reached" : this.input.dataset.placeholder || "add tag"
    this.input.classList.toggle("at-limit", atLimit)
    if (this.open && document.activeElement !== this.input) this.input.focus()
    this.highlight()
  },

  onInput() {
    const raw = this.input.value
    let value = raw.toLowerCase().replace(BANNED, "")
    const chars = Array.from(value)
    if (chars.length > MAX_LENGTH) value = chars.slice(0, MAX_LENGTH).join("")
    if (value !== raw) this.input.value = value
    this.selected = -1
    clearTimeout(this.queryTimer)
    this.queryTimer = setTimeout(() => this.query(value), QUERY_DEBOUNCE_MS)
  },

  onKey(e) {
    const value = this.input.value.trim()
    const options = this.suggestionEls()
    switch (e.key) {
      case "Enter": {
        e.preventDefault()
        const chosen = options[this.selected]
        if (chosen) this.add(chosen.dataset.label)
        else if (value) this.add(value)
        break
      }
      case "Backspace": {
        if (this.input.value === "") {
          const chips = this.root.querySelectorAll("[data-label]:not([data-role])")
          const last = chips[chips.length - 1]
          if (last) {
            e.preventDefault()
            this.pushEvent(this.el.dataset.onRemove, {label: last.dataset.label})
          }
        }
        break
      }
      case "Escape": {
        e.preventDefault()
        // the field owns Escape: a dialog around it (Open a room) listens on
        // the window and would close on the same press
        e.stopPropagation()
        if (this.input.value) {
          this.input.value = ""
          this.query("")
        } else {
          this.setOpen(false)
        }
        break
      }
      case "ArrowDown": {
        if (options.length) {
          e.preventDefault()
          this.selected = (this.selected + 1) % options.length
          this.highlight()
        }
        break
      }
      case "ArrowUp": {
        if (options.length) {
          e.preventDefault()
          this.selected = (this.selected - 1 + options.length) % options.length
          this.highlight()
        }
        break
      }
      default:
        break
    }
  },

  onBlur() {
    if (!this.el.contains(document.activeElement) && this.input.value === "") {
      this.setOpen(false)
    }
  },

  add(label) {
    this.pushEvent(this.el.dataset.onAdd, {label})
    this.input.value = ""
    this.selected = -1
    clearTimeout(this.queryTimer)
  },

  query(q) {
    if (this.gone) return
    this.pushEvent(this.el.dataset.onQuery, {q})
  },

  suggestionEls() {
    return Array.from(this.el.querySelectorAll("[data-role=suggestion]"))
  },

  highlight() {
    this.suggestionEls().forEach((el, i) => {
      el.setAttribute("aria-selected", i === this.selected ? "true" : "false")
    })
  }
}

export default TagInput

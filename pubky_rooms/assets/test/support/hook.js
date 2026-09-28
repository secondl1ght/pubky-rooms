// Mounts a LiveView hook the way LiveView does: `this` is an object carrying
// the hook's callbacks plus `el`, `pushEvent`, `pushEventTo` and
// `handleEvent`. `pushes` records every push, `fire` delivers a server event
// registered with `handleEvent`, and `update` runs the beforeUpdate/updated
// pair after a DOM mutation, as LiveView would after a patch.
import {vi} from "vitest"

export function mountHook(Hook, html, {select} = {}) {
  const wrapper = document.createElement("div")
  wrapper.innerHTML = html.trim()
  document.body.appendChild(wrapper)
  const el = select ? wrapper.querySelector(select) : wrapper.firstElementChild

  const handlers = {}
  const pushes = []
  const hook = Object.assign({}, Hook, {
    el,
    pushEvent: vi.fn((event, payload) => {
      pushes.push({event, payload})
      return Promise.resolve({})
    }),
    pushEventTo: vi.fn(() => Promise.resolve({})),
    handleEvent: vi.fn((name, cb) => {
      handlers[name] = cb
    })
  })
  hook.mounted && hook.mounted()

  return {
    hook,
    el,
    wrapper,
    pushes,
    fire(name, payload = {}) {
      if (!handlers[name]) throw new Error(`no handler for ${name}`)
      handlers[name](payload)
    },
    update(mutate) {
      hook.beforeUpdate && hook.beforeUpdate()
      mutate && mutate()
      hook.updated && hook.updated()
    },
    unmount() {
      hook.destroyed && hook.destroyed()
      wrapper.remove()
    }
  }
}

export function keydown(el, key, init = {}) {
  const event = new KeyboardEvent("keydown", {key, bubbles: true, cancelable: true, ...init})
  el.dispatchEvent(event)
  return event
}

export function input(el, value) {
  el.value = value
  el.dispatchEvent(new Event("input", {bubbles: true}))
}

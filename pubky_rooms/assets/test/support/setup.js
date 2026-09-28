// jsdom lacks the layout and platform APIs the hooks touch; give them
// harmless defaults so a test only stubs what it asserts on.
import {vi} from "vitest"

Element.prototype.scrollIntoView ??= function () {}

if (!navigator.clipboard) {
  Object.defineProperty(navigator, "clipboard", {
    value: {writeText: vi.fn(() => Promise.resolve())},
    configurable: true
  })
}

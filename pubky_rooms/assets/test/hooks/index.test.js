import {describe, expect, it} from "vitest"
import hooks from "../../js/hooks/index"

describe("hooks registry", () => {
  it("exports every hook the templates reference", () => {
    expect(Object.keys(hooks).sort()).toEqual(["AutoDismiss", "Clipboard", "Composer", "ScrollToBottom", "TagInput"])
    for (const hook of Object.values(hooks)) expect(typeof hook.mounted).toBe("function")
  })
})

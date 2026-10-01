// Avatars: an <img data-avatar> that fails to load is removed so the
// generative fallback underneath shows. One capturing listener for the whole
// page (image error events do not bubble) instead of a hook per image: a hook
// needs a unique DOM id, and the same picture appears in several places at
// once (composer, members, rows), which broke LiveView's patching.
export function installAvatarFallback(root = document) {
  root.addEventListener(
    "error",
    e => {
      const el = e.target
      if (el && el.matches && el.matches("img[data-avatar]")) el.remove()
    },
    true
  )
}

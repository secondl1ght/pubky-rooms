// Airplane mode: LiveView navigates over its socket, so with no network a
// link click and the back button do nothing and the page looks stuck. When
// the browser reports no connection, a link click becomes a full page load
// and a history move reloads, which the service worker answers with the
// offline page (or the real page, the moment the network is back).
export function installOfflineNavigation({
  win = window,
  isOffline = () => !navigator.onLine,
  navigate = href => win.location.assign(href),
  reload = () => win.location.reload()
} = {}) {
  win.addEventListener(
    "click",
    e => {
      if (!isOffline() || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return
      const link = e.target && e.target.closest && e.target.closest("a[data-phx-link][href]")
      if (!link) return
      e.preventDefault()
      e.stopImmediatePropagation()
      navigate(link.href)
    },
    true
  )
  win.addEventListener("popstate", () => {
    if (isOffline()) reload()
  })
}

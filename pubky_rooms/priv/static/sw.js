// Pubky Rooms service worker.
//
// Scope: make the app installable and instant to reopen, nothing more.
//   * digested static assets (/assets, /fonts, /images) are cache-first: their
//     names change with their content, so a cached copy is always right
//   * every page navigation is network-only (LiveView renders live state; a
//     cached page would be stale and its websocket would reconnect anyway);
//     when the network fails the static offline page is shown instead
//   * everything else (long-poll fallback, health, API) is left to the network
// The LiveView websocket is not a fetch and is never touched. Bumping VERSION
// drops every old cache on activation (v2: v1 had been registered in dev, where
// asset names are not hashed; the bump makes those browsers refetch app.js,
// whose dev build unregisters the worker). No push handling yet: web push for
// mentions/replies can be added here later without changing the strategy.
const VERSION = "pubky-rooms-v5"
const OFFLINE_URL = "/offline.html"
const ASSET_PREFIXES = ["/assets/", "/fonts/", "/images/"]

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(VERSION).then(cache => cache.add(OFFLINE_URL)).then(() => self.skipWaiting())
  )
})

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  )
})

self.addEventListener("fetch", event => {
  const request = event.request
  if (request.method !== "GET") return
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return

  if (ASSET_PREFIXES.some(prefix => url.pathname.startsWith(prefix))) {
    event.respondWith(cacheFirst(request))
  } else if (request.mode === "navigate") {
    event.respondWith(networkWithOfflineFallback(request))
  }
})

async function cacheFirst(request) {
  const cache = await caches.open(VERSION)
  const cached = await cache.match(request)
  if (cached) return cached
  const response = await fetch(request)
  if (response.ok) cache.put(request, response.clone())
  return response
}

async function networkWithOfflineFallback(request) {
  try {
    return await fetch(request)
  } catch (_error) {
    const cache = await caches.open(VERSION)
    return (await cache.match(OFFLINE_URL)) || Response.error()
  }
}

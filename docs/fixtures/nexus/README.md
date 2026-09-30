# Nexus responses (captured)

Real answers of the staging Nexus (`https://nexus.staging.pubky.app`) on
2026-09-30, for the test room `0035SBMXT68RR` of the staging identity
`hckj…btky`, used by `pubky_rooms/test/pubky_rooms/nexus_test.exs`:

- `stream_resources.json` — `GET /v0/stream/resources?app=pubky-rooms&limit=5`:
  a list of `{"details": {"id","uri","scheme","indexed_at"}, "tags": [...], "taggers_count"}`.
- `resource_by_uri.json` — `GET /v0/resource/by-uri?uri=pubky://…/pub/pubky-rooms/rooms/0035SBMXT68RR`:
  one `{"resource": {"id","uri","scheme","indexed_at"}, "tags": [...]}` — note the
  `resource` key instead of `details`, and no `taggers_count`. An unknown URI is a 404.

Each tag is `{"label","taggers": [z32, …],"taggers_count","relationship"}`.
Re-capture when Nexus changes its schema; `PubkyRooms.Nexus` parses both shapes.

# ADR 0003 — Room discovery via Nexus universal tags

**Status:** accepted (2026-09-10)

**Context.** Nexus v0.4 indexes tags written by any app at `/pub/<app>/tags/<id>` and exposes the tagged URIs as Resources under that app namespace (`GET /v0/stream/resources?app=…`). Pubky App can add tags to any URI too.

**Decision.** On creating a public room, Pubky Rooms writes `PubkyAppTag` files in its own namespace (`/pub/pubky-rooms/tags/`) targeting the room URI, with an automatic `room` label plus creator-chosen topic labels. Discovery in the lobby (mainnet) and in Pubky App's Rooms page queries the Nexus resources stream with `app=pubky-rooms`. No extra pubky.app capabilities are requested.

**Consequences.** Rooms participate in the semantic social graph (anyone can tag a room; web-of-trust filtering applies); unlisted rooms get no tags; rooms from homeservers Nexus does not watch only appear in the local directory.

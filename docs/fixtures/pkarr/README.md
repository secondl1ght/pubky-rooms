# PKARR relay payload fixtures (public data)

Captured from `https://pkarr.pubky.org/<z32>` on 2026-09-11. Body layout: `sig(64) || timestamp_us(8, big-endian) || dns_packet`.

- `user_ihaqcth.payload.hex` — user `ihaqcthsdbk751sxctk849bdr7yz7a934qen5gmpcbwcur49i97y` (official Pubky profile). One RR: `_pubky.<user> HTTPS 0 8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty`. Timestamp `1788680981480831`.
- `homeserver_8um71.payload.hex` — homeserver `8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty`. RRs: `HTTPS 1 . port=6287 ipv4hint=34.65.156.171`, `HTTPS 10 homeserver.pubky.app`, `A 34.65.156.171`. Timestamp `1788168146956031`.

Re-capture: `curl -s https://pkarr.pubky.org/<z32> | xxd -p | tr -d '\n'`.

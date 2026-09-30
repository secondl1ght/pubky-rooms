import Config

# The endpoint listens on 4002 for the browser (e2e) tests in test/e2e, which
# drive real Chromium through PhoenixTest's Playwright driver against the same
# fakes as every other test (`Pubky.Fake`, `FakeGrantLogin`). They are tagged
# :e2e and excluded by default: `mix test --include e2e` (see test_helper.exs).
config :pubky_rooms, PubkyRoomsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "wCpdJlFdsb0j9HVjK/ysvlx0M54S/YUKbh+RdYxz9rutbffuCeB5tVK8P8sUTqHV",
  server: true

config :phoenix_test,
  otp_app: :pubky_rooms,
  playwright: [
    # the playwright package lives in assets/ (installed by `npm ci`)
    assets_dir: "./assets",
    headless: true,
    timeout: 5_000,
    browser_launch_timeout: 20_000,
    js_logger: PubkyRooms.E2E.Console,
    screenshot_dir: "tmp/e2e-screenshots",
    # baselines for test/vrt (assert_screenshot); diffs go to <dir>/__diff__ (gitignored)
    snapshot_dir: "test/vrt/snapshots",
    trace_dir: "tmp/e2e-traces"
  ]

# Print only warnings and errors during test
config :logger, level: :warning

config :pubky, network: :testnet, client_id: "rooms.test"

config :pubky_rooms,
  data_dir: "tmp/test-data",
  pubky_backend: PubkyRooms.Pubky.Fake,
  confirm_timeout_ms: 200,
  attach_timeout_ms: 300,
  room_idle_timeout_ms: 100,
  bootstrap_per_member: 10,
  bootstrap_messages: 5,
  member_poll_ms: 100,
  viewers_debounce_ms: 50,
  subscription_detach_grace_ms: 100,
  subscription_retry_ms: 100,
  grant_login: PubkyRooms.Auth.FakeGrantLogin

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

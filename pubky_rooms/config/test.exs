import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pubky_rooms, PubkyRoomsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "wCpdJlFdsb0j9HVjK/ysvlx0M54S/YUKbh+RdYxz9rutbffuCeB5tVK8P8sUTqHV",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :pubky, network: :testnet, client_id: "rooms.test"

config :pubky_rooms,
  data_dir: "tmp/test-data",
  pubky_backend: PubkyRooms.Pubky.Fake,
  confirm_timeout_ms: 200,
  room_idle_timeout_ms: 100,
  bootstrap_per_member: 10,
  bootstrap_messages: 5,
  member_poll_ms: 100,
  viewers_debounce_ms: 50

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

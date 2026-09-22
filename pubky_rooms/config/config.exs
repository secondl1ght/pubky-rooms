# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pubky_rooms,
  generators: [timestamp_type: :utc_datetime],
  # Pubky Rooms application settings (see docs/notes/rooms-app-design.md)
  app_id: "pubky-rooms",
  data_dir: "priv/data",
  # history bootstrap: list up to N entries per member, fetch only the newest M overall
  bootstrap_per_member: 50,
  bootstrap_messages: 100,
  fetch_concurrency: 16,
  page_size: 50,
  reactions_per_member: 1_000,
  # live event subscriptions per room (creator first); members beyond this are
  # polled every member_poll_ms instead. The stream pool (PUBKY_STREAM_POOL_SIZE
  # × 50 users) bounds the total per homeserver per node.
  max_members_subscribed: 5_000,
  member_poll_ms: 60_000,
  # viewer totals per room are announced at most once per this window
  viewers_debounce_ms: 2_000,
  # rooms stay warm (subscribed, cached) this long after the last viewer leaves…
  room_idle_timeout_ms: 1_800_000,
  # …unless more than this many room processes are alive, then rooms *without viewers*
  # stop right away (never a limit on rooms that exist or have viewers)
  max_idle_rooms: 200,
  confirm_timeout_ms: 15_000,
  profile_ttl_ms: 900_000,
  # sessions are dropped from memory 60 s after the last connected LiveView leaves; entries that
  # never had one (plain HTTP requests) expire after this much inactivity (the cookie re-seeds them)
  session_memory_ttl_ms: 900_000,
  secure_cookies: false,
  pubky_backend: PubkyRooms.Pubky.Live,
  nexus_url: nil,
  # how often the Nexus resources stream is polled for rooms tagged anywhere (mainnet only)
  nexus_sync_ms: 300_000,
  # closed rooms (read-only archives) nobody opened for this long are forgotten
  closed_room_ttl_ms: 7_776_000_000,
  nexus_cdn_url: nil,
  simulator_url: nil

# Pubky client defaults; config/runtime.exs overrides these from the environment.
config :pubky,
  network: :mainnet,
  client_id: "rooms.pubky.app"

# Configure the endpoint
config :pubky_rooms, PubkyRoomsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PubkyRoomsWeb.ErrorHTML, json: PubkyRoomsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PubkyRooms.PubSub,
  live_view: [signing_salt: "2WSEWrQz"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  pubky_rooms: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  pubky_rooms: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use the Elixir stdlib JSON module for JSON parsing in Phoenix
config :phoenix, :json_library, JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

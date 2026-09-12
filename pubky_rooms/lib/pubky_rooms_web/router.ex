defmodule PubkyRoomsWeb.Router do
  use PubkyRoomsWeb, :router

  import PubkyRoomsWeb.UserAuth, only: [fetch_current_user: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PubkyRoomsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PubkyRoomsWeb do
    pipe_through :browser

    get "/auth/complete", AuthController, :complete
    delete "/logout", AuthController, :logout

    live_session :default, on_mount: [{PubkyRoomsWeb.UserAuth, :mount_current_user}] do
      live "/", LobbyLive, :index
      live "/rooms/new", LobbyLive, :new
      live "/r/:creator/:room_id", RoomLive, :show
      live "/r/:creator/:room_id/settings", RoomLive, :settings
      live "/login", AuthLive, :index
      live "/me", MeLive, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", PubkyRoomsWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:pubky_rooms, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PubkyRoomsWeb.Telemetry
      live "/ui", PubkyRoomsWeb.Dev.StyleguideLive, :index
    end
  end
end

defmodule PubkyRoomsWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Content Security Policy and the other browser hardening headers for every
  HTML response (the `:browser` pipeline, after `put_secure_browser_headers`).

  The policy is strict because the app needs little: scripts come only from
  our digested `app.js` (LiveView, hooks) plus a per-request nonce that
  LiveDashboard uses for its inline charts in dev; styles from `app.css` and
  the inline `style` attributes that colour avatars and tag chips; images
  from ourselves, `data:` URIs and any `https:` host (avatars live on
  homeservers and the Nexus CDN; `csp_img_src` adds `http:` for the local
  testnet); connections only to ourselves, including the LiveView websocket
  (`ws(s)://<host>`); fonts self-hosted (plus `data:` for LiveDashboard's
  embedded icon font in dev); no framing at all; a service worker
  and a manifest from ourselves. There is no third-party script, style,
  font, frame or beacon anywhere (ADR 0006).
  """
  @behaviour Plug

  import Plug.Conn

  @permissions "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(conn, nonce))
    |> put_resp_header("permissions-policy", @permissions)
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
  end

  @doc "The policy string for this request (exposed for tests)."
  @spec policy(Plug.Conn.t(), String.t()) :: String.t()
  def policy(conn, nonce) do
    img = Enum.join(["'self'", "data:", "https:" | extra_img_sources()], " ")

    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}'",
      "style-src 'self' 'unsafe-inline'",
      "img-src #{img}",
      "font-src 'self' data:",
      "connect-src 'self' #{socket_origins(conn)}",
      "frame-src 'self'",
      "frame-ancestors 'none'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "manifest-src 'self'",
      "worker-src 'self'"
    ]
    |> Enum.join("; ")
  end

  # The LiveView socket on this host; both schemes so a page served over
  # HTTPS behind a proxy that speaks HTTP to us still matches.
  defp socket_origins(conn) do
    port =
      case {conn.scheme, conn.port} do
        {:http, 80} -> ""
        {:https, 443} -> ""
        {_, port} -> ":#{port}"
      end

    "ws://#{conn.host}#{port} wss://#{conn.host}#{port}"
  end

  defp extra_img_sources, do: Application.get_env(:pubky_rooms, :csp_img_src, [])
end

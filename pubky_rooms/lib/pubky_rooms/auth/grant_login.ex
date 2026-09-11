defmodule PubkyRooms.Auth.GrantLogin do
  @moduledoc """
  Starts and completes Pubky Ring sign-in flows for Pubky Rooms.

  The app asks for a single capability, read/write under its namespace, and
  identifies itself with the configured client id (`config :pubky, :client_id`).
  """

  alias Pubky.Auth.GrantFlow

  @capabilities ["/pub/pubky-rooms/:rw"]

  @doc "The capabilities Pubky Rooms requests."
  def capabilities, do: @capabilities

  @doc "Starts a sign-in flow; render `authorization_url/1` as a QR code."
  @spec start() :: GrantFlow.t()
  def start, do: GrantFlow.start(caps: @capabilities, kind: :signin)

  @doc "The `pubkyauth://` URL to show the user."
  @spec authorization_url(GrantFlow.t()) :: String.t()
  def authorization_url(flow), do: GrantFlow.authorization_url(flow)

  @doc "Blocks until the user approves (or the flow times out); returns the session."
  @spec await(GrantFlow.t(), pos_integer()) :: {:ok, Pubky.Session.t()} | {:error, term()}
  def await(flow, timeout_ms \\ 120_000), do: GrantFlow.await(flow, timeout_ms)
end

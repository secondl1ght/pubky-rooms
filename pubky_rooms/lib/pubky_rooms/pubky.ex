defmodule PubkyRooms.Pubky do
  @moduledoc """
  The app's façade over the `pubky` library.

  Every homeserver interaction goes through this module so that tests can
  swap in `PubkyRooms.Pubky.Fake` (an in-memory homeserver that emits events
  synchronously). The backend is `config :pubky_rooms, :pubky_backend`.

  Reads are addressed by user; writes by the login session id (`sid`) whose
  credentials `PubkyRooms.Auth.SessionStore` holds. Errors are normalized to
  a small vocabulary the UI can explain:

    * `:not_found`, `:unauthorized`, `:quota`, `:too_large`, `{:rate_limited, ms}`,
      `:unreachable`, `{:http, status}`, `{:unexpected, term}`
  """

  @type user :: String.t()
  @type sid :: String.t()
  @type reason ::
          :not_found
          | :unauthorized
          | :quota
          | :too_large
          | {:rate_limited, pos_integer()}
          | :unreachable
          | {:http, non_neg_integer()}
          | {:unexpected, term()}
  @type listing :: %{entries: [Pubky.Resource.t()], next_cursor: String.t() | nil}

  @callback get(user(), String.t()) :: {:ok, binary()} | {:error, reason()}
  @callback list(user(), String.t(), keyword()) :: {:ok, listing()} | {:error, reason()}
  @callback put(sid(), String.t(), iodata(), String.t()) :: :ok | {:error, reason()}
  @callback delete(sid(), String.t()) :: :ok | {:error, reason()}
  @callback latest_cursor(user(), String.t()) ::
              {:ok, non_neg_integer() | nil} | {:error, reason()}
  @callback homeserver_of(user()) :: {:ok, String.t()} | {:error, reason()}
  @callback public_url(user(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  @callback start_stream(keyword()) :: {:ok, pid()} | {:error, term()}
  @callback add_users(pid(), [{user(), non_neg_integer() | nil}]) :: :ok
  @callback remove_users(pid(), [user()]) :: :ok
  @callback stop_stream(pid()) :: :ok
  @callback stop_all_streams() :: :ok

  @doc "The configured backend module."
  @spec backend() :: module()
  def backend, do: Application.get_env(:pubky_rooms, :pubky_backend, PubkyRooms.Pubky.Live)

  @doc "Reads a public file from the user's homeserver."
  def get(user, path), do: backend().get(user, path)

  @doc "Lists a directory (`limit`, `cursor`, `reverse`, `shallow`)."
  def list(user, dir, opts \\ []), do: backend().list(user, dir, opts)

  @doc "Writes a file as the session's user."
  def put(sid, path, body, content_type \\ "application/json"),
    do: backend().put(sid, path, body, content_type)

  @doc "Deletes a file as the session's user."
  def delete(sid, path), do: backend().delete(sid, path)

  @doc "The newest event cursor for the user under `path`."
  def latest_cursor(user, path), do: backend().latest_cursor(user, path)

  @doc "The user's current homeserver."
  def homeserver_of(user), do: backend().homeserver_of(user)

  @doc "A URL a browser can load for one of the user's public files."
  def public_url(user, path), do: backend().public_url(user, path)

  @doc "Starts an event stream (see `Pubky.Events.Stream` options)."
  def start_stream(opts), do: backend().start_stream(opts)
  def add_users(pid, users), do: backend().add_users(pid, users)
  def remove_users(pid, users), do: backend().remove_users(pid, users)
  def stop_stream(pid), do: backend().stop_stream(pid)

  @doc "Stops every event stream (a restarted subscriptions process starts afresh)."
  def stop_all_streams, do: backend().stop_all_streams()

  @doc "Maps library errors to the app's error vocabulary."
  @spec normalize(term()) :: :ok | {:ok, term()} | {:error, reason()}
  def normalize(:ok), do: :ok
  def normalize({:ok, value}), do: {:ok, value}
  def normalize({:error, :not_found}), do: {:error, :not_found}
  def normalize({:error, {:http, 404, _}}), do: {:error, :not_found}

  def normalize({:error, {:http, status, _}}) when status in [401, 403],
    do: {:error, :unauthorized}

  def normalize({:error, :grant_revoked}), do: {:error, :unauthorized}
  def normalize({:error, :no_session}), do: {:error, :unauthorized}
  def normalize({:error, {:http, 507, _}}), do: {:error, :quota}
  def normalize({:error, {:http, 413, _}}), do: {:error, :too_large}
  def normalize({:error, {:body_too_large, _}}), do: {:error, :too_large}
  def normalize({:error, {:http, 429, _}}), do: {:error, {:rate_limited, 5_000}}
  def normalize({:error, {:rate_limited, ms}}), do: {:error, {:rate_limited, ms || 5_000}}
  def normalize({:error, {:http, status, _}}), do: {:error, {:http, status}}
  def normalize({:error, {:transport, _}}), do: {:error, :unreachable}
  def normalize({:error, :no_icann_endpoint}), do: {:error, :unreachable}
  def normalize({:error, {:relay, _}}), do: {:error, :unreachable}
  def normalize({:error, :unreachable}), do: {:error, :unreachable}
  def normalize({:error, reason}), do: {:error, {:unexpected, reason}}
end

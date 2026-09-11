defmodule Pubky.Test.FakeHomeserver do
  @moduledoc """
  A minimal in-memory homeserver served through Bypass for unit tests.

  Implements the grant auth endpoints (verifying grant and proof signatures the
  way a real homeserver does), `/info`, and the storage API in either
  addressing mode. State lives in an `Agent` so tests can inspect it.
  """

  import Plug.Conn

  alias Pubky.Auth.{Grant, Jws}
  alias Pubky.Crypto.Blake3
  alias Pubky.{Keypair, PublicKey}

  defstruct [:bypass, :agent, :keypair, :z32, :base_url, path_addressed: true, token_ttl: 3600]

  @doc "Starts a fake homeserver. Options: `path_addressed: false` to emulate legacy servers, `token_ttl:` seconds."
  def start(opts \\ []) do
    bypass = Bypass.open()

    {:ok, agent} =
      Agent.start_link(fn -> %{users: MapSet.new(), tokens: %{}, files: %{}, packets: %{}} end)

    keypair = Keypair.generate()

    hs = %__MODULE__{
      bypass: bypass,
      agent: agent,
      keypair: keypair,
      z32: Keypair.public_z32(keypair),
      base_url: "http://localhost:#{bypass.port}",
      path_addressed: Keyword.get(opts, :path_addressed, true),
      token_ttl: Keyword.get(opts, :token_ttl, 3600)
    }

    Bypass.stub(bypass, :any, :any, &handle(&1, hs))
    hs
  end

  @doc """
  A config that uses this fake as both the homeserver (via override) and the
  PKARR relay (`/pkarr/<z32>` routes), so nothing touches the real network.
  """
  def config(%__MODULE__{} = hs, overrides \\ []) do
    Pubky.Config.mainnet(
      [pkarr_relays: [hs.base_url <> "/pkarr"], homeserver_overrides: %{hs.z32 => hs.base_url}] ++
        overrides
    )
  end

  def files(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1.files)
  def packets(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1.packets)
  def users(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1.users)
  def tokens(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1.tokens)

  @doc "Expires every issued token (forces clients to refresh)."
  def expire_tokens(%__MODULE__{agent: agent}) do
    Agent.update(agent, fn s ->
      %{s | tokens: Map.new(s.tokens, fn {t, v} -> {t, %{v | expires_at: 0}} end)}
    end)
  end

  # ── routing ────────────────────────────────────────────────────────────────

  defp handle(conn, hs) do
    case {conn.method, conn.request_path} do
      {"PUT", "/pkarr/" <> z32} ->
        {:ok, body, conn} = read_body(conn)

        case Pubky.Pkarr.SignedPacket.decode_relay_payload(z32, body) do
          {:ok, _} ->
            Agent.update(hs.agent, &%{&1 | packets: Map.put(&1.packets, z32, body)})
            resp(conn, 204, "")

          {:error, reason} ->
            resp(conn, 400, inspect(reason))
        end

      {"GET", "/pkarr/" <> z32} ->
        case Map.fetch(packets(hs), z32) do
          {:ok, body} ->
            conn
            |> put_resp_header("content-type", "application/pkarr.org/relays#payload")
            |> resp(200, body)

          :error ->
            resp(conn, 404, "")
        end

      {"GET", "/info"} ->
        features = if hs.path_addressed, do: ["path-addressed-storage"], else: []
        json(conn, 200, %{features: features})

      {"POST", "/auth/grant/signup"} ->
        with {:ok, grant, _client_pk} <- verify_grant_and_pop(conn, hs),
             true <-
               grant.client_id == "pubky.signup" ||
                 {:error, 400, "signup grant must use pubky.signup"} do
          Agent.update(hs.agent, &%{&1 | users: MapSet.put(&1.users, grant.iss)})
          resp(conn, 204, "")
        else
          {:error, status, msg} -> resp(conn, status, msg)
        end

      {"POST", "/auth/grant/session"} ->
        with {:ok, grant, _client_pk} <- verify_grant_and_pop(conn, hs),
             true <- grant.iss in users(hs) || {:error, 404, "unknown user"} do
          token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          now = System.os_time(:second)
          expires = now + hs.token_ttl

          Agent.update(hs.agent, fn s ->
            %{
              s
              | tokens:
                  Map.put(s.tokens, token, %{
                    user: grant.iss,
                    expires_at: expires,
                    grant_id: grant.jti,
                    caps: grant.caps
                  })
            }
          end)

          json(conn, 200, %{
            token: token,
            session: %{
              homeserver: hs.z32,
              pubky: grant.iss,
              client_id: grant.client_id,
              capabilities: Enum.map(grant.caps, &to_string/1),
              grant_id: grant.jti,
              token_expires_at: expires,
              grant_expires_at: grant.exp,
              created_at: now
            }
          })
        else
          {:error, status, msg} -> resp(conn, status, msg)
        end

      {"GET", "/auth/grant/session"} ->
        case bearer(conn, hs) do
          {:ok, t} -> json(conn, 200, %{pubky: t.user, grant_id: t.grant_id})
          :error -> resp(conn, 401, "unauthorized")
        end

      {"DELETE", "/auth/grant/session"} ->
        case bearer(conn, hs) do
          {:ok, t} ->
            Agent.update(hs.agent, fn s ->
              %{s | tokens: Map.reject(s.tokens, fn {_, v} -> v.grant_id == t.grant_id end)}
            end)

            resp(conn, 200, "")

          :error ->
            resp(conn, 200, "")
        end

      _ ->
        storage(conn, hs)
    end
  end

  defp storage(conn, hs) do
    case owner_and_path(conn, hs) do
      {:ok, owner, path} ->
        cond do
          conn.method in ["GET", "HEAD"] and String.ends_with?(path, "/") ->
            list(conn, hs, owner, path)

          conn.method in ["GET", "HEAD"] ->
            read(conn, hs, owner, path)

          conn.method in ["PUT", "DELETE"] ->
            write(conn, hs, owner, path)

          true ->
            resp(conn, 405, "")
        end

      :error ->
        resp(conn, 400, "Can't extract PubkyHost")
    end
  end

  defp owner_and_path(conn, %{path_addressed: true}) do
    case String.split(conn.request_path, "/", parts: 4) do
      ["", "storage", owner, rest] ->
        if PublicKey.valid?(owner), do: {:ok, owner, "/" <> rest}, else: :error

      _ ->
        :error
    end
  end

  defp owner_and_path(conn, %{path_addressed: false}) do
    case get_req_header(conn, "pubky-host") do
      [owner] -> if PublicKey.valid?(owner), do: {:ok, owner, conn.request_path}, else: :error
      _ -> :error
    end
  end

  defp read(conn, hs, owner, path) do
    private? = not String.starts_with?(path, "/pub/")

    with :ok <- if(private?, do: authorize(conn, hs, owner), else: :ok) do
      case Map.fetch(files(hs), {owner, path}) do
        {:ok, %{body: body, content_type: ct}} ->
          etag = ~s("#{Base.encode64(Blake3.hash(body))}")

          if get_req_header(conn, "if-none-match") == [etag] do
            resp(conn, 304, "")
          else
            conn
            |> put_resp_header("content-type", ct)
            |> put_resp_header("etag", etag)
            |> put_resp_header("last-modified", "Thu, 10 Sep 2026 00:00:00 GMT")
            |> resp(200, if(conn.method == "HEAD", do: "", else: body))
          end

        :error ->
          resp(conn, 404, "not found")
      end
    else
      {:error, status, msg} -> resp(conn, status, msg)
    end
  end

  defp list(conn, hs, owner, dir) do
    params = URI.decode_query(conn.query_string)
    limit = params |> Map.get("limit", "100") |> String.to_integer()
    reverse? = Map.get(params, "reverse") == "true"
    cursor = Map.get(params, "cursor")

    entries =
      files(hs)
      |> Map.keys()
      |> Enum.filter(fn {o, p} -> o == owner and String.starts_with?(p, dir) end)
      |> Enum.map(fn {o, p} -> "pubky://#{o}#{p}" end)
      |> Enum.sort()
      |> then(&if(reverse?, do: Enum.reverse(&1), else: &1))
      |> then(fn list ->
        case cursor do
          nil -> list
          c -> list |> Enum.drop_while(&(&1 != c)) |> Enum.drop(1)
        end
      end)
      |> Enum.take(limit)

    conn |> put_resp_header("content-type", "text/plain") |> resp(200, Enum.join(entries, "\n"))
  end

  defp write(conn, hs, owner, path) do
    with :ok <- authorize(conn, hs, owner) do
      case conn.method do
        "PUT" ->
          {:ok, body, conn} = read_body(conn)
          ct = List.first(get_req_header(conn, "content-type")) || "application/octet-stream"

          Agent.update(hs.agent, fn s ->
            %{s | files: Map.put(s.files, {owner, path}, %{body: body, content_type: ct})}
          end)

          resp(conn, 201, "")

        "DELETE" ->
          if Map.has_key?(files(hs), {owner, path}) do
            Agent.update(hs.agent, fn s -> %{s | files: Map.delete(s.files, {owner, path})} end)
            resp(conn, 204, "")
          else
            resp(conn, 404, "not found")
          end
      end
    else
      {:error, status, msg} -> resp(conn, status, msg)
    end
  end

  defp authorize(conn, hs, owner) do
    case bearer(conn, hs) do
      {:ok, %{user: ^owner}} -> :ok
      {:ok, _} -> {:error, 403, "forbidden"}
      :error -> {:error, 401, "unauthorized"}
    end
  end

  defp bearer(conn, hs) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %{expires_at: exp} = t when is_map(t) <- Map.get(tokens(hs), token),
         true <- exp > System.os_time(:second) do
      {:ok, t}
    else
      _ -> :error
    end
  end

  defp verify_grant_and_pop(conn, hs) do
    {:ok, body, _conn} = read_body(conn)

    with {:ok, %{"grant" => grant_jws, "pop" => pop_jws}} <- JSON.decode(body),
         {:ok, grant} <- Grant.decode(grant_jws, verify: true),
         false <- Grant.expired?(grant),
         {:ok, client_pk} <- PublicKey.to_bytes(grant.cnf),
         true <- Jws.verify(pop_jws, client_pk),
         {:ok,
          %{header: %{"typ" => "pubky-pop"}, claims: %{"aud" => aud, "gid" => gid, "iat" => iat}}} <-
           Jws.decode(pop_jws),
         true <- aud == hs.z32,
         true <- gid == grant.jti,
         true <- abs(iat - System.os_time(:second)) <= 180 do
      {:ok, grant, client_pk}
    else
      _ -> {:error, 401, "invalid grant or proof"}
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> resp(status, JSON.encode!(data))
  end
end

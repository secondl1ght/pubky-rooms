defmodule Pubky.Resource do
  @moduledoc """
  A `pubky://<user>/<path>` resource reference: a user's public key plus an
  absolute storage path such as `/pub/pubky.app/profile.json`.
  """

  alias Pubky.PublicKey

  @type t :: %__MODULE__{user: PublicKey.z32(), path: String.t()}
  @enforce_keys [:user, :path]
  defstruct [:user, :path]

  @doc "Parses a `pubky://` URI."
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse("pubky://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [user, path] ->
        with {:ok, z32} <- PublicKey.parse(user),
             do: {:ok, %__MODULE__{user: z32, path: "/" <> path}}

      [user] ->
        with {:ok, z32} <- PublicKey.parse(user), do: {:ok, %__MODULE__{user: z32, path: "/"}}
    end
  end

  def parse(_), do: :error

  @doc "Builds a resource from a user and an absolute path."
  @spec new(PublicKey.z32(), String.t()) :: t()
  def new(user, "/" <> _ = path), do: %__MODULE__{user: user, path: path}

  @doc "The canonical `pubky://` URI."
  @spec to_uri(t()) :: String.t()
  def to_uri(%__MODULE__{user: user, path: path}), do: "pubky://" <> user <> path

  defimpl String.Chars do
    def to_string(r), do: Pubky.Resource.to_uri(r)
  end
end

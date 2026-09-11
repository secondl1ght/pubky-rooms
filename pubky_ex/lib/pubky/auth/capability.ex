defmodule Pubky.Auth.Capability do
  @moduledoc """
  Capabilities scope what a session may do: `"<scope>:<actions>"`, e.g.
  `"/pub/pubky-rooms/:rw"`.

  The scope is an absolute storage path. A trailing slash matters: `/pub/app/`
  covers everything under the directory while `/pub/app` names one file.
  Actions are `r` (read) and/or `w` (write). Several capabilities are joined
  with commas.
  """

  @type t :: %__MODULE__{scope: String.t(), actions: [:read | :write]}
  defstruct scope: "/", actions: [:read, :write]

  @doc "Read+write on everything (`/:rw`)."
  @spec root() :: t()
  def root, do: %__MODULE__{scope: "/", actions: [:read, :write]}

  @doc "Read+write on a scope."
  @spec read_write(String.t()) :: {:ok, t()} | {:error, :invalid_scope}
  def read_write(scope), do: new(scope, [:read, :write])

  @doc "Read-only on a scope."
  @spec read(String.t()) :: {:ok, t()} | {:error, :invalid_scope}
  def read(scope), do: new(scope, [:read])

  @doc "Builds a capability, validating the scope."
  @spec new(String.t(), [:read | :write]) :: {:ok, t()} | {:error, :invalid_scope}
  def new(scope, actions) when is_binary(scope) and actions != [] do
    if valid_scope?(scope),
      do: {:ok, %__MODULE__{scope: scope, actions: Enum.uniq(actions)}},
      else: {:error, :invalid_scope}
  end

  @doc "Parses a capability string such as `/pub/app/:rw`."
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_capability | :invalid_scope}
  def parse(str) when is_binary(str) do
    case String.split(str, ":") do
      [scope, actions] when actions != "" ->
        with {:ok, parsed} <- parse_actions(actions), do: new(scope, parsed)

      _ ->
        {:error, :invalid_capability}
    end
  end

  @doc "Formats as `scope:actions` (`r` before `w`)."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{scope: scope, actions: actions}) do
    scope <>
      ":" <> if(:read in actions, do: "r", else: "") <> if :write in actions, do: "w", else: ""
  end

  @doc "Joins capabilities into the comma-separated wire form."
  @spec join([t()]) :: String.t()
  def join(caps), do: Enum.map_join(caps, ",", &format/1)

  @doc "Splits the comma-separated wire form."
  @spec split(String.t()) :: {:ok, [t()]} | {:error, term()}
  def split(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse(item) do
        {:ok, cap} -> {:cont, {:ok, [cap | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, caps} -> {:ok, Enum.reverse(caps)}
      err -> err
    end
  end

  defp parse_actions(str) do
    str
    |> String.graphemes()
    |> Enum.reduce_while({:ok, []}, fn
      "r", {:ok, acc} -> {:cont, {:ok, acc ++ [:read]}}
      "w", {:ok, acc} -> {:cont, {:ok, acc ++ [:write]}}
      _, _ -> {:halt, {:error, :invalid_capability}}
    end)
  end

  defp valid_scope?(scope) do
    String.starts_with?(scope, "/") and not String.contains?(scope, [":", ",", "\n", " "]) and
      not String.contains?(scope, "..")
  end

  defimpl String.Chars do
    def to_string(cap), do: @for.format(cap)
  end
end

defmodule PubkyRooms.E2E.Console do
  @moduledoc """
  Collects the browser console during the e2e tests (`test/e2e`), as the
  `PlaywrightEx.JsLogger` configured under `:phoenix_test, :playwright`: the
  smoke test asserts that a full navigation leaves no errors or warnings
  (a CSP violation shows up here as an error).
  """
  @behaviour PlaywrightEx.JsLogger

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @doc "Forgets everything collected so far."
  def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

  @doc "Every console line so far, oldest first, as `{level, text}`."
  def messages, do: Agent.get(__MODULE__, &Enum.reverse/1)

  @doc "The warnings and errors so far."
  def problems, do: Enum.filter(messages(), fn {level, _} -> level in [:warning, :error] end)

  @impl true
  def log(level, text, _msg), do: Agent.update(__MODULE__, &[{level, text} | &1])
end

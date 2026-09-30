defmodule PubkyRooms.SafeTask do
  @moduledoc """
  Runs the body of a fire-and-forget task so that a crash still yields a
  result.

  Servers that hand work to `Task.Supervisor.start_child/2` and wait for a
  message back (room paging and backfills, mute and profile loads, stream
  resolution) would otherwise keep their "in flight" state forever when the
  task raises or exits: `run/2` returns `fallback.()` instead. The failure is
  logged without the term that caused it, so message content and public keys
  stay out of info-level logs (ADR 0006); the full report is at debug.
  """

  require Logger

  @doc "Calls `fun`; on a raise or exit logs it and returns `fallback.()`."
  @spec run((-> result), (-> result)) :: result when result: term()
  def run(fun, fallback) when is_function(fun, 0) and is_function(fallback, 0) do
    fun.()
  rescue
    e ->
      Logger.warning("background task raised #{inspect(e.__struct__)}")
      Logger.debug(Exception.format(:error, e, __STACKTRACE__))
      fallback.()
  catch
    :exit, reason ->
      Logger.warning("background task exited")
      Logger.debug("background task exit: #{inspect(reason)}")
      fallback.()
  end
end

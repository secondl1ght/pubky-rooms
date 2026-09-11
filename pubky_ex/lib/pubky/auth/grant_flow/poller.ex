defmodule Pubky.Auth.GrantFlow.Poller do
  @moduledoc """
  Runs a `Pubky.Auth.GrantFlow` in its own process and reports the outcome to
  the caller as a message, so a LiveView can render the QR code and keep
  handling events while the relay is polled:

      flow = Pubky.Auth.GrantFlow.start(caps: ["/pub/my-app/:rw"])
      {:ok, _pid} = Pubky.Auth.GrantFlow.Poller.start_link(flow, notify: self(), ref: ref)
      # later: {:pubky_auth, ^ref, {:ok, %Pubky.Session{}}} or {:pubky_auth, ^ref, {:error, reason}}

  The poller is linked to the caller by default, so it dies with the LiveView.
  """

  alias Pubky.Auth.GrantFlow

  @doc "Starts a linked poller. Options: `notify:` (pid, default caller), `ref:` (any term echoed back)."
  @spec start_link(GrantFlow.t(), keyword()) :: {:ok, pid()}
  def start_link(%GrantFlow{} = flow, opts \\ []) do
    {notify, ref} = options(opts)
    {:ok, spawn_link(fn -> run(flow, notify, ref) end)}
  end

  @doc "Starts an unlinked poller under `Pubky.TaskSupervisor`."
  @spec start(GrantFlow.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%GrantFlow{} = flow, opts \\ []) do
    {notify, ref} = options(opts)
    Task.Supervisor.start_child(Pubky.TaskSupervisor, fn -> run(flow, notify, ref) end)
  end

  defp options(opts),
    do: {Keyword.get(opts, :notify, self()), Keyword.get(opts, :ref, make_ref())}

  defp run(flow, notify, ref) do
    remaining = max(flow.deadline - System.monotonic_time(:millisecond), 0)
    send(notify, {:pubky_auth, ref, GrantFlow.await(flow, remaining)})
  end
end

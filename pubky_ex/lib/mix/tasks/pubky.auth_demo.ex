defmodule Mix.Tasks.Pubky.AuthDemo do
  @shortdoc "Runs the Pubky Ring sign-in flow interactively (testnet by default)"
  @moduledoc """
  Prints a `pubkyauth://` link, waits for Pubky Ring (or the Ring Simulator at
  https://simulator.pubkyring.app for the local testnet) to approve it, then
  exchanges the grant for a session and writes a test file.

      mix pubky.auth_demo                       # testnet relay/homeserver
      mix pubky.auth_demo --mainnet             # public relay, real Pubky Ring
      mix pubky.auth_demo --caps /pub/my-app/:rw --client-id my-app.example
  """
  use Mix.Task

  alias Pubky.Auth.GrantFlow
  alias Pubky.{Config, Session, Storage}

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [mainnet: :boolean, caps: :string, client_id: :string, timeout: :integer]
      )

    Mix.Task.run("app.start")

    config =
      if opts[:mainnet],
        do: Config.mainnet(client_id: opts[:client_id] || "pubky-ex.demo"),
        else: Config.testnet(client_id: opts[:client_id] || "pubky-ex.demo")

    caps = [opts[:caps] || "/pub/pubky-ex.demo/:rw"]
    flow = GrantFlow.start([caps: caps], config)

    Mix.shell().info("""

    Approve this request in Pubky Ring#{if opts[:mainnet], do: "", else: " (Ring Simulator, Shortcut mode)"}:

    #{GrantFlow.authorization_url(flow)}

    Waiting for approval…
    """)

    case GrantFlow.await(flow, opts[:timeout] || 300_000) do
      {:ok, %Session{} = session} ->
        Mix.shell().info(
          "Signed in as #{session.user} on homeserver #{session.homeserver} (#{session.base_url})"
        )

        Mix.shell().info(
          "Capabilities: #{Enum.map_join(session.capabilities, ", ", &to_string/1)}"
        )

        path = "/pub/pubky-ex.demo/hello.txt"

        case Storage.put(
               session,
               path,
               "hello from pubky_ex",
               [content_type: "text/plain"],
               config
             ) do
          :ok -> Mix.shell().info("Wrote pubky://#{session.user}#{path}")
          {:error, reason} -> Mix.shell().error("Write failed: #{inspect(reason)}")
        end

        Mix.shell().info("Credential (keep secret): #{Session.export(session)}")

      {:error, reason} ->
        Mix.raise("Sign-in failed: #{inspect(reason)}")
    end
  end
end

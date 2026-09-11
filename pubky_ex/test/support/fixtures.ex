defmodule Pubky.Test.Fixtures do
  @moduledoc "Captured protocol payloads (public data) used across the test suite."

  @dir Path.expand("../fixtures", __DIR__)

  @user_z32 "ihaqcthsdbk751sxctk849bdr7yz7a934qen5gmpcbwcur49i97y"
  @homeserver_z32 "8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty"

  def user_z32, do: @user_z32
  def homeserver_z32, do: @homeserver_z32

  @doc "Raw relay payload bytes for the official Pubky profile key (user → homeserver)."
  def user_payload, do: hex("pkarr/user_ihaqcth.payload.hex")

  @doc "Raw relay payload bytes for the mainnet homeserver key."
  def homeserver_payload, do: hex("pkarr/homeserver_8um71.payload.hex")

  defp hex(name),
    do: @dir |> Path.join(name) |> File.read!() |> String.trim() |> Base.decode16!(case: :lower)
end

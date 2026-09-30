defmodule PubkyRooms.E2E.Steps do
  @moduledoc """
  Steps shared by the browser suites (`test/e2e`, `test/vrt`): the grant
  sign-in through `FakeGrantLogin`, the way a person would do it.
  """
  import PhoenixTest

  alias PubkyRooms.Auth.FakeGrantLogin
  alias PubkyRooms.Fixtures

  @doc """
  Signs the browser in as `z32`: opens the sign-in page, resolves the fake
  Ring flow, and returns once the header shows the account control.
  """
  def sign_in(conn, z32) do
    conn = conn |> visit("/login") |> assert_has("body", text: "Waiting for approval")
    FakeGrantLogin.resolve({:ok, Fixtures.session(z32)})
    assert_has(conn, "a[href='/me']")
  end
end

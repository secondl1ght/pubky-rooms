defmodule PubkyRooms.PubkyTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.Pubky

  test "library errors normalise to the reasons the app handles" do
    assert Pubky.normalize({:error, {:body_too_large, 65_536}}) == {:error, :too_large}
    assert Pubky.normalize({:error, {:transport, :deadline}}) == {:error, :unreachable}
    assert Pubky.normalize({:error, :no_icann_endpoint}) == {:error, :unreachable}
    assert Pubky.normalize({:error, {:http, 401, ""}}) == {:error, :unauthorized}
  end
end

File.rm_rf!("tmp/test-data")
{:ok, _} = PubkyRooms.Pubky.Fake.start_link()
{:ok, _} = PubkyRooms.Auth.FakeGrantLogin.start_link()
ExUnit.start(exclude: [:testnet, :e2e, :vrt])

# The browser tests (test/e2e, tag :e2e; test/vrt, tag :vrt) need the Playwright
# driver: started only when they are included, so `mix test` needs no node at all.
if Enum.any?([:e2e, :vrt], &(&1 in ExUnit.configuration()[:include])) do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  {:ok, _} = PubkyRooms.E2E.Console.start_link()
  Application.put_env(:phoenix_test, :base_url, PubkyRoomsWeb.Endpoint.url())
end

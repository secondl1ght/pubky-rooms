File.rm_rf!("tmp/test-data")
{:ok, _} = PubkyRooms.Pubky.Fake.start_link()
{:ok, _} = PubkyRooms.Auth.FakeGrantLogin.start_link()
ExUnit.start(exclude: [:testnet])

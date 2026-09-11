File.rm_rf!("tmp/test-data")
{:ok, _} = PubkyRooms.Pubky.Fake.start_link()
ExUnit.start(exclude: [:testnet])

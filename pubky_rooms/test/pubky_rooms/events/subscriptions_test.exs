defmodule PubkyRooms.Events.SubscriptionsTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.Events.Subscriptions
  alias PubkyRooms.Fixtures
  alias PubkyRooms.Pubky.Fake

  setup do
    reset_state()
    Subscriptions.subscribe()
    :ok
  end

  test "acquiring a user attaches them to a stream and announces the status" do
    user = Fixtures.z32("sub")
    Subscriptions.acquire([user], self())
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    assert Subscriptions.status(user) == :attached
    assert Subscriptions.statuses([user, "unknown"]) == %{user => :attached}
    assert user in Fake.stream_users()

    # a stream disconnect marks its users; a reconnect clears them
    %{users: %{^user => %{stream: {hs, name}}}} = Subscriptions.info()
    send(Subscriptions, {:pubky_stream, {hs, name}, {:disconnected, :idle}})
    assert_receive {:subscription_status, ^user, {:error, {:disconnected, :idle}}}, 1_000
    send(Subscriptions, {:pubky_stream, {hs, name}, :connected})
    assert_receive {:subscription_status, ^user, :attached}, 1_000

    Subscriptions.release([user], self())
  end
end

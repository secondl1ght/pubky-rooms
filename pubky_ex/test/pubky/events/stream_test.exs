defmodule Pubky.Events.StreamTest do
  use ExUnit.Case, async: true

  alias Pubky.Auth.LocalSigner
  alias Pubky.Events.{Event, Stream}
  alias Pubky.{Events, Keypair, Storage}
  alias Pubky.Test.FakeHomeserver

  defp setup_hs(opts) do
    hs = FakeHomeserver.start(opts)
    config = FakeHomeserver.config(hs, client_id: "events.test")

    users =
      for _ <- 1..2 do
        kp = Keypair.generate()
        :ok = LocalSigner.signup(kp, hs.z32, [], config)
        {:ok, session} = LocalSigner.signin(kp, hs.z32, [], config)
        session
      end

    {hs, config, users}
  end

  defp start_stream(hs, config, opts) do
    {:ok, pid} =
      Stream.start_link(
        [
          homeserver: hs.z32,
          name: make_ref(),
          subscriber: self(),
          config: config,
          paths: ["/pub/app/"]
        ] ++ opts
      )

    assert_receive {:pubky_stream, _, :connected}, 2_000
    pid
  end

  test "delivers live PUT and DEL events for followed users only" do
    {hs, config, [alice, bob]} = setup_hs([])
    pid = start_stream(hs, config, users: [{alice.user, nil}])

    :ok = Storage.put(alice, "/pub/app/a", "hello", [], config)

    assert_receive {:pubky_event,
                    %Event{
                      type: :put,
                      user: user,
                      path: "/pub/app/a",
                      content_hash: hash,
                      cursor: c1
                    }},
                   2_000

    assert user == alice.user
    assert hash == Pubky.Crypto.Blake3.hash("hello")

    :ok = Storage.put(bob, "/pub/app/b", "x", [], config)
    :ok = Storage.put(alice, "/pub/other/ignored", "x", [], config)
    :ok = Storage.delete(alice, "/pub/app/a", config)
    assert_receive {:pubky_event, %Event{type: :del, path: "/pub/app/a", cursor: c2}}, 2_000
    assert c2 > c1
    refute_receive {:pubky_event, %Event{path: "/pub/app/b"}}, 200
    refute_receive {:pubky_event, %Event{path: "/pub/other/ignored"}}, 100

    assert Stream.cursors(pid) == %{alice.user => c2}

    # adding bob reconnects and backfills his history from the beginning
    :ok = Stream.add_users(pid, [{bob.user, nil}])
    assert_receive {:pubky_stream, _, {:disconnected, _}}, 2_000
    assert_receive {:pubky_stream, _, :connected}, 2_000
    assert_receive {:pubky_event, %Event{type: :put, path: "/pub/app/b"}}, 2_000
    refute_receive {:pubky_event, %Event{path: "/pub/app/a"}}, 200

    :ok = Stream.remove_users(pid, [alice.user])
    :ok = Storage.put(alice, "/pub/app/after", "x", [], config)
    refute_receive {:pubky_event, %Event{path: "/pub/app/after"}}, 300
    Stream.stop(pid)
  end

  test "resumes from the cursor after the connection drops, without duplicates" do
    {hs, config, [alice, _]} = setup_hs(drop_after: 2)
    for n <- 1..3, do: :ok = Storage.put(alice, "/pub/app/#{n}", "#{n}", [], config)

    pid = start_stream(hs, config, users: [{alice.user, nil}])
    assert_receive {:pubky_event, %Event{path: "/pub/app/1", cursor: 1}}, 2_000
    assert_receive {:pubky_event, %Event{path: "/pub/app/2", cursor: 2}}, 2_000
    # the fake drops the connection after two events; the stream reconnects with user=<z32>:2
    assert_receive {:pubky_stream, _, {:disconnected, :closed}}, 2_000
    assert_receive {:pubky_stream, _, :connected}, 5_000
    assert_receive {:pubky_event, %Event{path: "/pub/app/3", cursor: 3}}, 2_000
    refute_receive {:pubky_event, %Event{cursor: 1}}, 200
    refute_receive {:pubky_event, %Event{cursor: 2}}, 10

    assert Enum.any?(FakeHomeserver.requests(hs), &({"user", "#{alice.user}:2"} in &1))
    Stream.stop(pid)
  end

  test "the homeserver rejecting the subscription stops the stream" do
    {hs, config, _} = setup_hs([])
    Process.flag(:trap_exit, true)

    {:ok, pid} =
      Stream.start_link(
        homeserver: hs.z32,
        name: make_ref(),
        subscriber: self(),
        config: config,
        users: []
      )

    assert_receive {:pubky_stream, _, {:error, {:http, 400, _}}}, 2_000
    assert_receive {:EXIT, ^pid, {:shutdown, {:http, 400, _}}}, 2_000
  end

  test "supervised streams are registered and latest_cursor reports the newest event" do
    {hs, config, [alice, _]} = setup_hs([])
    assert Events.latest_cursor(hs.z32, alice.user, "/pub/app/", config) == {:ok, nil}
    :ok = Storage.put(alice, "/pub/app/x", "1", [], config)
    :ok = Storage.put(alice, "/pub/app/y", "2", [], config)
    assert Events.latest_cursor(hs.z32, alice.user, "/pub/app/", config) == {:ok, 2}

    name = make_ref()

    {:ok, pid} =
      Events.start_stream(
        homeserver: hs.z32,
        name: name,
        users: [{alice.user, 2}],
        subscriber: self(),
        config: config
      )

    assert Events.whereis(hs.z32, name) == pid
    assert_receive {:pubky_stream, _, :connected}, 2_000
    refute_receive {:pubky_event, _}, 200
    :ok = Storage.put(alice, "/pub/app/z", "3", [], config)
    assert_receive {:pubky_event, %Event{path: "/pub/app/z", cursor: 3}}, 2_000
    Stream.stop(pid)
    # registry cleanup is asynchronous
    assert Enum.any?(1..50, fn _ ->
             Events.whereis(hs.z32, name) == nil or (Process.sleep(10) && false)
           end)
  end
end

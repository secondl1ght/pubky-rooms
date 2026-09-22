defmodule PubkyRooms.NexusTest do
  use ExUnit.Case, async: false

  alias PubkyRooms.Nexus

  @uri "pubky://8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo/pub/pubky-rooms/rooms/0035PERXNDXFE"

  setup do
    Application.put_env(:pubky_rooms, :nexus_url, "http://nexus.test")
    Application.put_env(:pubky_rooms, :nexus_req_options, plug: {Req.Test, Nexus})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Application.delete_env(:pubky_rooms, :nexus_url)
      Application.delete_env(:pubky_rooms, :nexus_req_options)
    end)
  end

  test "disabled without a base url" do
    Application.delete_env(:pubky_rooms, :nexus_url)
    refute Nexus.enabled?()
    assert {:error, :disabled} = Nexus.resources()
    assert {:error, :disabled} = Nexus.tags_by_uri(@uri)
  end

  test "tags_by_uri parses a resource view; 404 means no tags; other statuses are errors" do
    Req.Test.stub(Nexus, fn conn ->
      assert conn.request_path == "/v0/resource/by-uri"
      assert conn.query_params["uri"] == @uri

      Req.Test.json(conn, %{
        "details" => %{"uri" => @uri},
        "tags" => [
          %{"label" => "room", "taggers" => ["a", "b"], "taggers_count" => 5},
          %{"label" => "music", "taggers_count" => 1},
          %{"nope" => true}
        ],
        "taggers_count" => 6
      })
    end)

    assert {:ok,
            [
              %{label: "room", count: 5, taggers: ["a", "b"]},
              %{label: "music", count: 1, taggers: []}
            ]} =
             Nexus.tags_by_uri(@uri)

    Req.Test.stub(Nexus, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert {:ok, []} = Nexus.tags_by_uri(@uri)

    Req.Test.stub(Nexus, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http, 500}} = Nexus.tags_by_uri(@uri)

    Req.Test.stub(Nexus, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, {:transport, _}} = Nexus.resources(sorting: "taggers_count", tags: ["a", "b"])
  end
end

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

  @fixtures Path.expand("../../../docs/fixtures/nexus", __DIR__)
  @staging_uri "pubky://hckjqy589fh554iu854gs788dnp8y49i3nc9yg76x4bhm7msbtky/pub/pubky-rooms/rooms/0035SBMXT68RR"

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> JSON.decode!()

  test "the captured staging responses parse: by-uri wraps the fields as \"resource\"" do
    Req.Test.stub(Nexus, fn conn ->
      case conn.request_path do
        "/v0/resource/by-uri" -> Req.Test.json(conn, fixture("resource_by_uri.json"))
        "/v0/stream/resources" -> Req.Test.json(conn, fixture("stream_resources.json"))
      end
    end)

    tagger = "hckjqy589fh554iu854gs788dnp8y49i3nc9yg76x4bhm7msbtky"

    assert {:ok,
            [
              %{label: "staging", count: 1, taggers: [^tagger]},
              %{label: "smoke", count: 1, taggers: [^tagger]},
              %{label: "room", count: 1, taggers: [^tagger]}
            ]} = Nexus.tags_by_uri(@staging_uri)

    assert {:ok, [%{uri: @staging_uri, taggers_count: 3, tags: [_, _, _]}]} = Nexus.resources()
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
          %{"label" => "  Music ", "taggers_count" => 1},
          %{"label" => String.duplicate("x", 40), "taggers_count" => 9},
          %{"label" => "two words", "taggers_count" => 9},
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

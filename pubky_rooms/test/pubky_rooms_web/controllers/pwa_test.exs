defmodule PubkyRoomsWeb.PwaTest do
  use PubkyRoomsWeb.ConnCase, async: true

  test "the manifest, service worker, offline page and icons are served", %{conn: conn} do
    conn = get(conn, "/manifest.webmanifest")
    assert conn.status == 200
    manifest = JSON.decode!(conn.resp_body)
    assert manifest["name"] == "Pubky Rooms"
    assert manifest["start_url"] == "/"
    assert manifest["display"] == "standalone"
    assert manifest["theme_color"] == "#05050A"
    icons = Enum.map(manifest["icons"], & &1["src"])
    assert "/images/icons/icon-512.png" in icons
    assert Enum.any?(manifest["icons"], &(&1["purpose"] =~ "maskable"))

    for src <- icons do
      assert get(build_conn(), src).status == 200, "icon #{src} missing"
    end

    sw = get(build_conn(), "/sw.js")
    assert sw.status == 200
    assert sw.resp_body =~ ~r/const VERSION = "pubky-rooms-v\d+"/
    # navigations are never cached, only assets and the offline page
    assert sw.resp_body =~ ~s(request.mode === "navigate")
    assert sw.resp_body =~ "/offline.html"

    offline = get(build_conn(), "/offline.html")
    assert offline.status == 200
    assert offline.resp_body =~ "You are offline"
    # served from the worker cache with no network: it may reference nothing
    # (the logo and the icon are inline; a path here would be a broken image offline)
    refute offline.resp_body =~ ~r/(src|href)="\//
    assert offline.resp_body =~ "<svg"
  end

  test "the root layout declares the manifest, icons and app-capable metas", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(<link rel="manifest" href="/manifest.webmanifest")
    assert html =~ ~s(rel="apple-touch-icon")
    assert html =~ ~s(name="theme-color" content="#05050A")
    assert html =~ ~s(name="mobile-web-app-capable" content="yes")
  end
end

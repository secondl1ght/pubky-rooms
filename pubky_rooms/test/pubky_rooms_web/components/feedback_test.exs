defmodule PubkyRoomsWeb.UI.FeedbackTest do
  use PubkyRoomsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PubkyRoomsWeb.UI.Feedback

  test "success and info toasts dismiss themselves after 5 s" do
    for kind <- [:success, :info] do
      html = render_component(&Feedback.flash/1, kind: kind, flash: %{to_string(kind) => "Done."})
      assert html =~ ~s(phx-hook="AutoDismiss")
      assert html =~ ~s(data-dismiss-after="5000")
    end
  end

  test "error toasts stay until dismissed" do
    html = render_component(&Feedback.flash/1, kind: :error, flash: %{"error" => "Failed."})
    refute html =~ "AutoDismiss"
    refute html =~ "data-dismiss-after"
  end

  test "the live indicator is decorative, brand-coloured and animates only when motion is allowed" do
    html = render_component(&Feedback.live_dot/1, [])
    assert html =~ ~s(aria-hidden="true")
    assert html =~ "bg-brand"
    assert html =~ "motion-safe:animate-live-ping"
  end

  test "the delay can be set per toast" do
    html =
      render_component(&Feedback.flash/1,
        kind: :info,
        dismiss_after: 1500,
        flash: %{"info" => "Hi"}
      )

    assert html =~ ~s(data-dismiss-after="1500")
  end
end

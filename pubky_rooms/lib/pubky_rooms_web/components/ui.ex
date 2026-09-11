defmodule PubkyRoomsWeb.UI do
  @moduledoc """
  The Pubky Rooms component library.

  A small, clean-room set of function components that reproduce the look of
  the Pubky App design system (dark theme, Inter Tight, Lucide icons, lime
  brand accent) for Phoenix LiveView. `use PubkyRoomsWeb.UI` imports every
  component module; templates get them automatically through
  `PubkyRoomsWeb, :html` / `:live_view`.

  Modules:

    * `PubkyRoomsWeb.UI.Icon` — Lucide icons and the Pubky logo
    * `PubkyRoomsWeb.UI.Button` — pill buttons with the Pubky variants
    * `PubkyRoomsWeb.UI.Avatar` — avatars with a generative fallback
    * `PubkyRoomsWeb.UI.Card` — cards and their sections
    * `PubkyRoomsWeb.UI.Badge` — small status labels
    * `PubkyRoomsWeb.UI.Tag` — colored tag chips
    * `PubkyRoomsWeb.UI.Form` — inputs, textareas, labels, errors
    * `PubkyRoomsWeb.UI.Dialog` — modal dialogs (bottom sheets on mobile)
    * `PubkyRoomsWeb.UI.Feedback` — flash toasts, spinner, skeleton, empty state
    * `PubkyRoomsWeb.UI.Typography` — the type scale
    * `PubkyRoomsWeb.UI.Layout` — page containers and sidebars
    * `PubkyRoomsWeb.UI.Transitions` — shared `Phoenix.LiveView.JS` show/hide helpers

  See `docs/design-system.md` for tokens and usage.
  """

  defmacro __using__(_opts) do
    quote do
      import PubkyRoomsWeb.UI.Avatar
      import PubkyRoomsWeb.UI.Badge
      import PubkyRoomsWeb.UI.Button
      import PubkyRoomsWeb.UI.Card
      import PubkyRoomsWeb.UI.Dialog
      import PubkyRoomsWeb.UI.Feedback
      import PubkyRoomsWeb.UI.Form
      import PubkyRoomsWeb.UI.Icon
      import PubkyRoomsWeb.UI.Layout
      import PubkyRoomsWeb.UI.Tag
      import PubkyRoomsWeb.UI.Transitions
      import PubkyRoomsWeb.UI.Typography
    end
  end
end

defmodule PubkyRoomsWeb.UI.Avatar do
  @moduledoc """
  Round user avatars.

  When no image is available (or it fails to load: `assets/js/avatar_fallback.js`
  removes the broken `<img data-avatar>`) a generative fallback is shown: a disc in one of the six Pubky signal colors, chosen from the user's
  public key, with the first letter of their name. `online` adds a small
  presence dot.
  """
  use Phoenix.Component

  @sizes %{
    "xs" => "size-5 text-[10px]",
    "sm" => "size-6 text-xs",
    "md" => "size-8 text-sm",
    "default" => "size-10 text-base",
    "lg" => "size-12 text-lg",
    "xl" => "size-16 text-2xl",
    "2xl" => "size-24 text-4xl"
  }

  @dots %{
    "xs" => "size-2 ring-1",
    "sm" => "size-2 ring-1",
    "md" => "size-2.5 ring-2",
    "default" => "size-3 ring-2",
    "lg" => "size-3 ring-2",
    "xl" => "size-4 ring-2",
    "2xl" => "size-5 ring-2"
  }

  # The six Pubky signal colors; the text color keeps contrast on each.
  @palette [
    {"#00FF5D", "#05050A"},
    {"#00F0FF", "#05050A"},
    {"#004BFF", "#FFFFFF"},
    {"#FC00FF", "#05050A"},
    {"#FF0000", "#FFFFFF"},
    {"#FF9900", "#05050A"}
  ]

  @doc """
  Renders an avatar.

      <.avatar src={@profile.avatar_url} name={@profile.name} pubky={@profile.pubky} />
      <.avatar name="Satoshi" pubky={pubky} size="lg" online />
  """
  attr :src, :string, default: nil
  attr :name, :string, default: nil, doc: "display name; its first letter is the fallback glyph"
  attr :pubky, :string, default: nil, doc: "public key used to pick the fallback color"
  attr :size, :string, default: "default", values: Map.keys(@sizes)
  attr :online, :boolean, default: false, doc: "shows a presence dot"
  attr :class, :any, default: nil
  attr :rest, :global

  def avatar(assigns) do
    {bg, fg} = fallback_colors(assigns.pubky || assigns.name || "")

    assigns =
      assigns
      |> assign(:size_classes, @sizes[assigns.size])
      |> assign(:dot_classes, @dots[assigns.size])
      |> assign(:initial, initial(assigns.name, assigns.pubky))
      |> assign(:fallback_style, "background-color: #{bg}; color: #{fg}")

    ~H"""
    <span
      class={["relative inline-flex shrink-0 align-middle select-none", @size_classes, @class]}
      {@rest}
    >
      <span class="relative flex size-full overflow-hidden rounded-full">
        <span
          class="flex size-full items-center justify-center font-bold uppercase leading-none"
          style={@fallback_style}
          aria-hidden={!!@src}
        >
          {@initial}
        </span>
        <%!-- no id and no hook: the same picture appears in several places at
             once, and a hook needs a unique id; a broken image is removed by
             the page-level listener in app.js (avatar_fallback.js) --%>
        <img
          :if={@src}
          src={@src}
          alt={@name || ""}
          class="absolute inset-0 size-full object-cover"
          data-avatar
          loading="lazy"
        />
      </span>
      <span
        :if={@online}
        class={["absolute right-0 bottom-0 rounded-full bg-brand ring-background", @dot_classes]}
        aria-label="online"
        role="img"
      />
    </span>
    """
  end

  @doc "Picks the `{background, foreground}` fallback colors for a seed (public key or name)."
  @spec fallback_colors(String.t()) :: {String.t(), String.t()}
  def fallback_colors(seed), do: Enum.at(@palette, :erlang.phash2(seed, length(@palette)))

  defp initial(name, pubky) do
    cond do
      is_binary(name) and String.trim(name) != "" -> name |> String.trim() |> String.first()
      is_binary(pubky) and pubky != "" -> String.first(pubky)
      true -> "?"
    end
  end
end

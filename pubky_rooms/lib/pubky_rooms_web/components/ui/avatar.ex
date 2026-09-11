defmodule PubkyRoomsWeb.UI.Avatar do
  @moduledoc """
  Round user avatars.

  When no image is available (or it fails to load) a generative fallback is
  shown: a disc in one of the six Pubky signal colors, chosen from the user's
  public key, with the first letter of their name.
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
      <.avatar name="Satoshi" pubky={pubky} size="lg" />
  """
  attr :src, :string, default: nil
  attr :name, :string, default: nil, doc: "display name; its first letter is the fallback glyph"
  attr :pubky, :string, default: nil, doc: "public key used to pick the fallback color"
  attr :size, :string, default: "default", values: Map.keys(@sizes)
  attr :class, :any, default: nil
  attr :rest, :global

  def avatar(assigns) do
    {bg, fg} = fallback_colors(assigns.pubky || assigns.name || "")

    assigns =
      assigns
      |> assign(:size_classes, @sizes[assigns.size])
      |> assign(:initial, initial(assigns.name, assigns.pubky))
      |> assign(:fallback_style, "background-color: #{bg}; color: #{fg}")

    ~H"""
    <span
      class={[
        "relative inline-flex shrink-0 overflow-hidden rounded-full align-middle select-none",
        @size_classes,
        @class
      ]}
      {@rest}
    >
      <span
        class="flex size-full items-center justify-center font-bold uppercase leading-none"
        style={@fallback_style}
        aria-hidden={!!@src}
      >
        {@initial}
      </span>
      <img
        :if={@src}
        id={"avatar-img-#{:erlang.phash2(@src)}"}
        src={@src}
        alt={@name || ""}
        class="absolute inset-0 size-full object-cover"
        phx-hook=".HideOnError"
        loading="lazy"
      />
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".HideOnError">
      export default {
        mounted() { this.el.addEventListener("error", () => this.el.remove(), {once: true}) }
      }
    </script>
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

defmodule PubkyRoomsWeb.Linkify do
  @moduledoc """
  Turns `http(s)://` URLs inside plain text into links, safely.

  Message text is never rendered as HTML: `linkify/1` splits the text into
  segments and lets HEEx escape each one; only recognized URLs become `<a>`
  elements, always with `rel="noopener noreferrer nofollow ugc"` and opening
  in a new tab. Trailing punctuation stays outside the link. `pubky://` URIs
  are left as text (browsers cannot open them).
  """
  use Phoenix.Component

  @url_re ~r/https?:\/\/[^\s<>"'`]+/iu
  @trailing ~r/[.,;:!?)\]}>'"]+$/u

  @doc "Splits text into `{:text, s}` and `{:link, url}` segments, in order."
  @spec segments(String.t()) :: [{:text, String.t()} | {:link, String.t()}]
  def segments(text) when is_binary(text) do
    @url_re
    |> Regex.split(text, include_captures: true)
    |> Enum.flat_map(fn part ->
      if Regex.match?(@url_re, part) and String.match?(part, ~r/^https?:\/\//i),
        do: split_trailing(part),
        else: text_segment(part)
    end)
    |> merge_text()
  end

  defp merge_text([{:text, a}, {:text, b} | rest]), do: merge_text([{:text, a <> b} | rest])
  defp merge_text([head | rest]), do: [head | merge_text(rest)]
  defp merge_text([]), do: []

  defp text_segment(""), do: []
  defp text_segment(s), do: [{:text, s}]

  # "see https://example.com/a)." → link "https://example.com/a", text ")."
  defp split_trailing(url) do
    case Regex.run(@trailing, url) do
      [tail] when tail != url ->
        clean = String.slice(url, 0, String.length(url) - String.length(tail))
        # keep a closing paren that balances one inside the URL (wikipedia-style)
        if String.starts_with?(tail, ")") and String.contains?(clean, "(") do
          [{:link, clean <> ")"} | text_segment(String.slice(tail, 1..-1//1))]
        else
          [{:link, clean} | text_segment(tail)]
        end

      _ ->
        [{:link, url}]
    end
  end

  @doc "Renders text with its URLs linked."
  attr :text, :string, required: true
  attr :class, :any, default: "text-brand underline decoration-brand/40 hover:decoration-brand"

  def linkify(assigns) do
    assigns = assign(assigns, :segments, segments(assigns.text))

    ~H"""
    <%= for segment <- @segments do %>
      <%= case segment do %>
        <% {:text, s} -> %>
          {s}
        <% {:link, url} -> %>
          <a
            href={url}
            rel="noopener noreferrer nofollow ugc"
            target="_blank"
            class={@class}
          >{url}</a>
      <% end %>
    <% end %>
    """
  end
end

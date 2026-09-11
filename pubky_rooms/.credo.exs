%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: ["lib/pubky_rooms_web/live/dev/"]},
      strict: true,
      checks: %{extra: [{Credo.Check.Readability.MaxLineLength, max_length: 120}]}
    }
  ]
}

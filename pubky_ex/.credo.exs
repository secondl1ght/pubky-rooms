%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: ["test/support/fake_homeserver.ex"]},
      strict: true,
      checks: %{enabled: [{Credo.Check.Readability.MaxLineLength, max_length: 120}]}
    }
  ]
}

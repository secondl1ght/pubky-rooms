# pubky-app-specs fixtures

Data copied from the official `pubky-app-specs` package (Rust crate published to
npm as WASM), so that the Elixir constants in Pubky Rooms can be checked
against the real thing. Which constants, and how to update them, is in
[`docs/notes/pubky-app-specs-mirror.md`](../../notes/pubky-app-specs-mirror.md).

| File | What it is |
|------|------------|
| `validationLimits.json` | verbatim copy of the package's `validationLimits.json` |
| `vectors.json` | reference outputs produced by running the package's `PubkySpecsBuilder` (tag ids, a timestamp id, validation outcomes) |
| `LICENSE` | the package's MIT licence (the data above is redistributed under it) |
| `VERSION` | the package version the two files came from |

## Refreshing

```bash
# from a checkout that has the package installed (Pubky App does)
ROOMS=/path/to/pubky-rooms          # this repository
cd /path/to/pubky-app && npm ls pubky-app-specs
cp node_modules/pubky-app-specs/validationLimits.json $ROOMS/docs/fixtures/pubky-app-specs/
node -e "console.log(require('pubky-app-specs/package.json').version)" > $ROOMS/docs/fixtures/pubky-app-specs/VERSION
```

Then regenerate `vectors.json` with the package (the script in the mirror
document), run `cd pubky_rooms && mix test test/pubky_rooms/spec_mirror_test.exs`,
and fix every constant the test names.

# pubky-app-specs mirror (living document)

**Keep this current.** Every rule Pubky Rooms takes from
[pubky-app-specs](https://github.com/pubky/pubky-app-specs) is listed here,
implemented in Elixir, and pinned by `pubky_rooms/test/pubky_rooms/spec_mirror_test.exs`
against data copied from the real package (`docs/fixtures/pubky-app-specs/`).

Why: pubky-app-specs is a Rust crate published to JavaScript as WASM. Rooms is
Elixir with no NIFs, so it cannot call the package; it reimplements the parts it
needs. Without this document and test, the numbers we copied once would drift
silently when the spec changes, and Rooms would write or read Pubky App data
differently from Pubky App. The first run of the test found one such drift
(tag `created_at` written in milliseconds where the spec uses microseconds).

The long-term shape is an Elixir `pubky_app_specs` package maintained alongside
the official one and bumped with it. Until that exists, this document is the
list of what such a package must cover, and the test is the conformance check.

## Rules

1. **Anything spec'd that Rooms starts reading or writing goes in the table below**
   in the same commit, with a constant in code, a fixture key or vector, and an
   assertion in `spec_mirror_test.exs`. No spec value lives only in a template or
   a comment.
2. **When the spec bumps**, refresh the fixtures (below), run the test, fix every
   constant it names, update the table and the `VERSION` file, and say so in the commit
   message.
3. Rooms' **own** formats (`/pub/pubky-rooms/…` rooms, members, messages,
   reactions, bans, mutes markers, nickname) are not the spec; they are documented
   in `docs/notes/rooms-app-design.md`. Where one of them deliberately shadows a
   spec limit (message length ≤ short post length) that relation is listed here
   and asserted as `<=`, not `==`.

## What Rooms mirrors (pubky-app-specs 0.7.0)

| Spec item | Spec value | Rooms | Pinned by |
|-----------|-----------|-------|-----------|
| Tag label length | `tagLabelMinLength` 1, `tagLabelMaxLength` 20 | `Tags.Tag.label_max/0`, `normalize/1` | limits |
| Tag banned characters | `tagInvalidChars` `, : space \t \n \r` (a tag is one word) | `Tags.Tag.banned_chars/0`, `normalize/1`; the `TagInput` hook strips the same set as the user types | limits, `tag_rejected_labels` |
| Tag label normalisation | trim + lowercase | `Tags.Tag.normalize/1` | `vectors.tags[].input_label → label` |
| Tag hash id | Crockford base32 of the first 16 bytes of blake3(`"{uri}:{label}"`), 26 chars | `Tags.Tag.id/2` | `vectors.tags[].id` (byte for byte) |
| Tag file | `{uri, label, created_at}` at `/pub/<app>/tags/<id>`; `created_at` in **microseconds** | `Tags.Tag.encode/2`, `decode/1`, `Rooms.Paths.tag/1` (namespace `pubky-rooms`) | `tag_json_keys`, `tag_created_at_unit` |
| Tags per item | `feedTagsMaxCount` 5 | create dialog: `max_custom_labels/0` (4) + automatic `room` ≤ 5 | limits (`<=`) |
| Timestamp id | 13-char Crockford base32 of the microsecond Unix time (big-endian u64) | `Ids.encode/1`, `decode/1`, `valid_id?/1` | `vectors.timestamp_ids` |
| Profile | `/pub/pubky.app/profile.json` `{name 3..50, bio ≤160, image ≤300, links ≤5, status ≤50}`; Rooms reads `name` and `image` | `Profiles` (`name_max/0` 50, `image_url_max/0` 300, `pubky_app_profile_path/0`) | limits, `user_names` |
| File record | `/pub/pubky.app/files/<ts id>` `{name, created_at, src, content_type, size}`; Rooms follows `src` to resolve a profile image | `Profiles.resolve_image/1` | `file_json_keys` |
| Mutes | `/pub/pubky.app/mutes/<z32>`; Rooms honours them read-only | `Mutes.app_mutes_dir/0` | path assertion |
| Public key | 52-char z-base32 | `Ids.valid_z32?/1` | `ids_test.exs` |
| Short post length | `postShortContentMaxLength` 2000 | `Rooms.Message.content_max/0` (Rooms' own limit, kept ≤) | limits (`<=`) |

Not mirrored on purpose: posts, bookmarks, follows, feeds, collections, blobs,
`last_read` (Rooms neither reads nor writes them), and `userNameMinLength`
(Rooms displays whatever name Pubky App accepted; it only caps the upper bound
when reading).

## Refreshing the fixtures

```bash
# 1. copy the limits and record the version (any checkout with the package; Pubky App has it)
ROOMS=/path/to/pubky-rooms          # this repository
cd /path/to/pubky-app && npm ls pubky-app-specs
cp node_modules/pubky-app-specs/validationLimits.json $ROOMS/docs/fixtures/pubky-app-specs/
node -e "console.log(require('pubky-app-specs/package.json').version)" > $ROOMS/docs/fixtures/pubky-app-specs/VERSION

# 2. regenerate the vectors with the package itself, then paste the output into vectors.json
node --input-type=module -e "
import * as specs from 'pubky-app-specs';
const me = '8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo';
const b = new specs.PubkySpecsBuilder(me);
for (const [uri, label] of [['pubky://' + me + '/pub/pubky-rooms/rooms/0035PERXNDXFE', '  BitCoin '], ['pubky://' + me + '/pub/pubky-rooms/rooms/0035R2S3QP3RY', '🔥']]) {
  const r = b.createTag(uri, label); console.log(uri, JSON.stringify(label), r.tag.label, r.meta.id, Object.keys(r.tag.toJson()), r.tag.toJson().created_at);
}
const f = b.createFile('pic.png', 'pubky://' + me + '/pub/pubky.app/blobs/0035PERXNDXFE', 'image/png', 10);
console.log(f.meta.id, f.file.toJson().created_at, Object.keys(f.file.toJson()));
"

# 3. run the conformance test and fix what it names
cd pubky_rooms && mix test test/pubky_rooms/spec_mirror_test.exs
```

## History

- 2026-09-22: created during the QA pause (spec 0.7.0). First run found tag
  `created_at` written in milliseconds; fixed to microseconds.

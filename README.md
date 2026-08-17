# tile-fonts

Signed-distance-field glyph sets for the Open Waters map styles, served from
`https://tiles.openwaters.io/fonts/{fontstack}/{range}.pbf`.

A MapLibre style needs a `glyphs` URL before it can draw a single label. This repo builds those
glyphs from Noto, verifies them, and publishes them to R2. It holds fonts only — sprites are a
different toolchain and get their own home.

## Why it is its own repo

The output is shared: every Open Waters map wants the same stacks, so no single product should
own them. Release cadence is the deciding argument, though — the seascape tile Worker keys
everything to a per-build R2 prefix, and fonts must be release-independent. Serving them from
that Worker would tie font availability to bathymetry deploys.

## Stacks

| Stack | Used for |
|---|---|
| `Noto Sans Italic` | Soundings and depth labels. S-4 §B-412.1 sets soundings in sloping sans-serif. |
| `Noto Sans Regular` | Place names, and soundings of lower reliability — §B-412.4 reserves upright numerals for exactly that. |
| `Noto Sans Medium` | Emphasis. |

Each stack is composed from many per-script Noto faces (see [fonts.json](fonts.json)), so
worldwide coverage is a font list rather than a code change. Stack names are the contract with
every published style: renaming one breaks every style that asks for it.

## Build

```sh
# Prebuilt binary (no Rust toolchain needed); or: cargo install build_pbf_glyphs
gh release download cli-v1.5.1 --repo stadiamaps/sdf_font_tools \
  --pattern 'build_pbf_glyphs.x86_64-apple-darwin' -O ~/.local/bin/build_pbf_glyphs
chmod +x ~/.local/bin/build_pbf_glyphs

scripts/build.sh                   # all stacks, or: scripts/build.sh "Noto Sans Italic"
scripts/verify.py                  # coverage gate
scripts/publish.sh --dry-run       # then without the flag
```

The macOS asset is named `x86_64` but ships a native arm64 binary.

`build.sh` fetches the Noto release pinned in `fonts.json` (a ~630 MB archive, cached under
`build/`), so rebuilding the same release is reproducible. Every stack's source paths are
resolved before any glyph is cut, and a missing one is fatal — not every family is in the
monolithic Noto repo (Tibetan is not), and a stack with a silent hole renders as tofu. Set
`STAGE_ONLY=1` to run just the fetch and resolve steps, which need no glyph tool.

Faces are merged in listed order, and that order decides who wins an overlapping codepoint —
the base Latin face is first so its digits are not shadowed by a script face.

Current output: Regular 12,225 glyphs, Medium 6,530, Italic 3,278, 256 ranges each.

## The coverage gate

`verify.py` fails the build when a stack is missing any codepoint the charts actually set, and
this is the reason the repo exists in its present shape. The MapLibre demo fontstack the seascape
style pointed at ships only U+2082–2084 of the subscript block: seven of the ten subscript digits
were absent. Nothing errors when that happens — the glyph is simply not drawn, so a sounding's
decimetre digit silently disappears from the chart. The check is an error, never a warning.

## Serving

R2 bucket on a custom domain. No Worker:

- **Caching** — Cloudflare caches from each object's own `Cache-Control`, set to
  `public, max-age=31536000, immutable` at upload. Range PBFs for a given release never change.
- **CORS** — configured on the bucket, or as a response-header rule on the hostname.
- **TLS and CDN** — come with the custom domain.

`tiles.openwaters.io` already routes `/seascape/*` to a Worker. A more specific Worker route
takes precedence over a custom domain, so the two coexist; if that proves awkward in practice, a
dedicated hostname costs nothing and changes only the `glyphs` URL in the styles.

## Licence

The fonts are [SIL Open Font License 1.1](OFL.txt) and are redistributed with it. Everything in
this repo that is not a font is BSD-3-Clause, matching the rest of Open Waters.

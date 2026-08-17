#!/usr/bin/env bash
# Build every fontstack in fonts.json into build/fonts/<Stack Name>/<start>-<end>.pbf.
#
#   scripts/build.sh [stack name ...]     # default: every stack
#
# Fonts come from the notofonts.github.io release pinned in fonts.json, so a rebuild of the
# same release is reproducible. Glyphs are cut by build_pbf_glyphs (Stadia's Rust CLI over
# the same sdf-glyph-foundry everything else wraps); it is a `cargo install`, where MapLibre's
# font-maker needs a cmake/make build from source.
#
# build_pbf_glyphs converts a DIRECTORY of fonts, one stack per file, then merges via a
# -c spec. So each stack is staged into its own directory of numbered symlinks — the number
# prefix fixes merge order, which is what decides who wins an overlapping codepoint (the base
# Latin face must come first or its digits lose to a script face's).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
# build_pbf_glyphs is checked later, immediately before it is used. Fetching and resolving every
# source path needs no Rust toolchain, and those are the steps that catch a wrong font list —
# finding out the list is bad should not require installing a compiler first.

RELEASE=$(jq -r .release fonts.json)
VARIANT=$(jq -r .variant fonts.json)
SRC="build/notofonts-$RELEASE"
OUT="build/fonts"

# ── Fetch the pinned Noto release once ───────────────────────────────────────
if [ ! -d "$SRC" ]; then
  echo "fetching notofonts $RELEASE"
  mkdir -p build
  tarball="build/noto-$RELEASE.tar.gz"
  [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
    "https://github.com/notofonts/notofonts.github.io/archive/refs/tags/$RELEASE.tar.gz"
  mkdir -p "$SRC"
  tar -xzf "$tarball" -C "$SRC" --strip-components=1
fi

stacks=("$@")
if [ ${#stacks[@]} -eq 0 ]; then
  IFS=$'\n' read -r -d '' -a stacks < <(jq -r '.stacks | keys[]' fonts.json && printf '\0')
fi

# ── Stage every stack first ──────────────────────────────────────────────────
# All the source paths are resolved before any glyph is cut, so a font that moved or was dropped
# from a release fails the whole run immediately instead of after some stacks are already built.
# Not every family ships in the monolithic Noto repo — Tibetan does not — and a stack with a
# silent hole is a script that renders as tofu, so a missing source is fatal, never skipped.
missing=0
for stack in "${stacks[@]}"; do
  stage="build/stage/$stack"
  rm -rf "$stage"; mkdir -p "$stage"
  i=0
  while IFS= read -r rel; do
    src="$SRC/fonts/$(dirname "$rel")/$VARIANT/$(basename "$rel")"
    if [ ! -f "$src" ]; then
      echo "  MISSING $stack: $rel" >&2
      missing=$((missing + 1))
      continue
    fi
    ln -sf "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" \
       "$stage/$(printf '%03d' "$i")-$(basename "$rel")"
    i=$((i + 1))
  done < <(jq -r --arg s "$stack" '.stacks[$s].sources[]' fonts.json)
  echo "staged $stack: $i faces"
done
[ "$missing" -eq 0 ] || {
  echo "$missing source font(s) missing from $RELEASE — refusing to build a stack with holes" >&2
  exit 1
}

if [ -n "${STAGE_ONLY:-}" ]; then
  echo "STAGE_ONLY set — stopping before glyph conversion"
  exit 0
fi
command -v build_pbf_glyphs >/dev/null || {
  echo "build_pbf_glyphs not found. Install it with:" >&2
  echo "  cargo install build_pbf_glyphs" >&2
  exit 1
}

mkdir -p "$OUT"
for stack in "${stacks[@]}"; do
  echo "== $stack"
  stage="build/stage/$stack"

  # Per-face stacks first, then one merge into the published name.
  #
  # build_pbf_glyphs names each output directory after the font's own internal name, not its
  # filename, so the merge spec cannot be written from the file list. Each face is converted on
  # its own and the directory that appears is recorded — the names are discovered, and merge
  # order stays the staged order, which is what decides who wins an overlapping codepoint.
  work="build/work/$stack"
  rm -rf "$work"; mkdir -p "$work"
  faces=()
  for face in "$stage"/*; do
    one=$(mktemp -d); ln -sf "$(readlink "$face")" "$one/$(basename "$face")"
    before=$(cd "$work" && find . -maxdepth 1 -mindepth 1 -type d | sort)
    build_pbf_glyphs "$one" "$work" >/dev/null
    after=$(cd "$work" && find . -maxdepth 1 -mindepth 1 -type d | sort)
    new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's|^\./||')
    rm -rf "$one"
    [ -n "$new" ] || { echo "  $(basename "$face") produced no glyphs" >&2; exit 1; }
    while IFS= read -r n; do faces+=("$n"); done <<< "$new"
  done

  spec="build/work/$stack.merge.json"
  printf '%s\n' "${faces[@]}" | jq -R . | jq -s --arg name "$stack" '{($name): .}' > "$spec"
  build_pbf_glyphs -c "$spec" "$stage" "$work"

  [ -d "$work/$stack" ] || { echo "  merge produced no '$stack' — check $spec" >&2; exit 1; }
  rm -rf "${OUT:?}/$stack"
  mkdir -p "$OUT"
  mv "$work/$stack" "$OUT/$stack"
  echo "  -> $OUT/$stack ($(ls "$OUT/$stack" | wc -l | tr -d ' ') ranges, ${#faces[@]} faces merged)"
done

echo
echo "built into $OUT — verify before publishing:"
echo "  scripts/verify.py"

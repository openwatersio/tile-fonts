#!/usr/bin/env bash
# Publish build/fonts to the R2 bucket behind tiles.openwaters.io/fonts.
#
#   scripts/publish.sh [--bucket tiles] [--prefix fonts/] [--dry-run]
#
# There is no Worker in this path. A glyph PBF is an immutable static file, and an R2 bucket on
# a custom domain already gives caching, TLS and CORS — Cloudflare caches from each object's own
# Cache-Control, which is why it is set here at upload rather than in code. Publishing is
# therefore a sync, and font serving never rides a bathymetry deploy.
#
# Range PBFs for a given release never change, so they are marked immutable for a year. A stack
# is republished wholesale under its own name; the name is the contract with every style that
# asks for it, so renaming one is a breaking change, not a redeploy.
set -euo pipefail
cd "$(dirname "$0")/.."

BUCKET=tiles
PREFIX=fonts/
DRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --dry-run) DRY="--dryrun"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -d build/fonts ] || { echo "build/fonts missing — run scripts/build.sh" >&2; exit 1; }

# Never ship a stack the coverage check rejects; a missing glyph is silent at render time.
scripts/verify.py build/fonts

echo
echo "publishing build/fonts -> s3://$BUCKET/$PREFIX ${DRY:+(dry run)}"
aws s3 sync build/fonts "s3://$BUCKET/$PREFIX" $DRY \
  --exclude "*" --include "*.pbf" \
  --content-type application/x-protobuf \
  --cache-control "public, max-age=31536000, immutable"

echo
echo "done. spot-check a range:"
echo "  curl -sI https://tiles.openwaters.io/${PREFIX}Noto%20Sans%20Regular/0-255.pbf"

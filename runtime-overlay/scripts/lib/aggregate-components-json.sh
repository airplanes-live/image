#!/usr/bin/env bash
# aggregate-components-json.sh — collect per-component SHA files
# (components.<key>.sha, one full 40-hex SHA per file) into a single
# components.json the manifest renderer consumes.
#
# Input:  per-component SHA files at <staging>/components.<key>.sha
# Output: <staging>/components.json — { "<key>": "<sha>", ... }
#
# Why a separate helper:
#   The cross-compile / stage helpers each write their own
#   components.<key>.sha so each helper is self-contained and produces a
#   single composable atom. build-release.sh consumes a single
#   components.json. This helper closes that gap. Tests and the eventual
#   release workflow both share this code path.
#
# Composition with the rest of the runtime-overlay build pipeline:
#
#   1. Per-component helpers populate a shared <staging> dir:
#        cross-compile-readsb.sh   --output-dir <staging>
#        cross-compile-dump978.sh  --output-dir <staging>
#        stage-tar1090.sh          --output-dir <staging>
#        stage-graphs1090.sh       --output-dir <staging>
#      Each writes its slice of bin/, share/, systemd/, etc/... plus a
#      components.<key>.sha file at the staging root.
#
#   2. Operator-curated JSON snippets get dropped into <staging>:
#        managed_paths.json, mutable_paths.json, systemd.json,
#        migrations.json, compat.json
#      These are part of the runtime-overlay source tree, not produced by
#      the per-component helpers — the release workflow copies them in.
#
#   3. This helper aggregates the per-component SHA files into a single
#      components.json at the staging root:
#        aggregate-components-json.sh --input-dir <staging>
#
#   4. build-release.sh (one level up) consumes the resulting staging dir
#      and produces the canonical release tree:
#        build-release.sh --input-dir <staging> --output-dir <releases> ...
#
# Args:
#   --input-dir <staging>     directory containing components.<key>.sha files
#   --output <path>           where to write components.json
#                             (default: <staging>/components.json)

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: aggregate-components-json.sh \
    --input-dir <staging-dir> \
    [--output <path>]
USAGE
}

die() {
    echo "aggregate-components-json: $*" >&2
    exit 1
}

INPUT_DIR=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input-dir)  INPUT_DIR="${2-}";  shift 2 ;;
        --output)     OUTPUT="${2-}";     shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; echo "aggregate-components-json: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$INPUT_DIR" ]] || { usage; die "missing --input-dir"; }
[[ -d "$INPUT_DIR" ]] || die "--input-dir not a directory: $INPUT_DIR"

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$INPUT_DIR/components.json"
fi

# Collect under LC_ALL=C so the emitted key order is stable across
# locales — jq -S re-sorts again on write, but a stable input order makes
# pre-render diffs deterministic.
shopt -s nullglob
mapfile -t SHA_FILES < <(LC_ALL=C find "$INPUT_DIR" -maxdepth 1 -type f \
    -name 'components.*.sha' -printf '%f\n' | LC_ALL=C sort)

if [[ "${#SHA_FILES[@]}" -eq 0 ]]; then
    die "no components.<key>.sha files found in $INPUT_DIR"
fi

# Build JSON via jq so embedded escape paths are correct. Start from {}
# and add a key per file. The SHA is read from the file (trimmed of
# trailing whitespace) and validated lexically — the schema enforces
# component SHA shape too, but failing here makes the diagnostic point
# at the offending file, not at a downstream schema error.
JSON='{}'
for filename in "${SHA_FILES[@]}"; do
    path="$INPUT_DIR/$filename"
    # filename = "components.<key>.sha"
    key="${filename#components.}"
    key="${key%.sha}"
    if [[ -z "$key" ]]; then
        die "malformed component SHA filename: $filename"
    fi
    sha="$(tr -d '[:space:]' < "$path")"
    if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
        die "$path: SHA must be 7..40 lowercase hex chars (got: $sha)"
    fi
    # If a companion components.<key>.version file exists, emit an object
    # {commit_sha, version} instead of a bare SHA string. This lets downstream
    # consumers (manifest, health gates) carry the version tag alongside the pin.
    version_file="$INPUT_DIR/components.${key}.version"
    if [[ -f "$version_file" ]]; then
        ver="$(tr -d '[:space:]' < "$version_file")"
        JSON="$(printf '%s' "$JSON" \
            | jq -S --arg k "$key" --arg s "$sha" --arg v "$ver" \
              '. + {($k): {commit_sha: $s, version: $v}}')"
    else
        JSON="$(printf '%s' "$JSON" \
            | jq -S --arg k "$key" --arg v "$sha" '. + {($k): $v}')"
    fi
done

# Atomic write.
tmp="$(mktemp "${OUTPUT}.XXXXXX")"
printf '%s\n' "$JSON" > "$tmp"
mv -f -- "$tmp" "$OUTPUT"

echo "aggregate-components-json: wrote $OUTPUT (${#SHA_FILES[@]} components)"

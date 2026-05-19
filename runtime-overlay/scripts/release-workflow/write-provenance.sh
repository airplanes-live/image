#!/usr/bin/env bash
# write-provenance.sh — emit PROVENANCE.md alongside a runtime-overlay
# release tree. Documents source SHAs per component, the workflow run that
# produced the artifacts, and pointers to upstream license texts. The file
# is uploaded as a release asset and consumed as the release-notes body.
#
# Args:
#   --release-dir <path>   the v<X> release tree (must contain manifest.json)
#   --run-url <url>        GitHub Actions run URL (optional; included if set)
#   --output <path>        where to write PROVENANCE.md (default:
#                          <release-dir>/PROVENANCE.md)
#
# Determinism: the file is sorted by component key, so two runs against the
# same manifest emit byte-identical PROVENANCE.md (modulo the run URL).

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: write-provenance.sh --release-dir <path> [--run-url <url>] [--output <path>]
USAGE
}

die() {
    echo "write-provenance: $*" >&2
    exit 1
}

RELEASE_DIR=""
RUN_URL=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release-dir) RELEASE_DIR="${2-}"; shift 2 ;;
        --run-url)     RUN_URL="${2-}";     shift 2 ;;
        --output)      OUTPUT="${2-}";      shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done

[[ -n "$RELEASE_DIR" ]] || { usage; die "missing --release-dir"; }
[[ -d "$RELEASE_DIR" ]] || die "--release-dir not a directory: $RELEASE_DIR"

manifest="$RELEASE_DIR/manifest.json"
[[ -f "$manifest" ]] || die "no manifest.json under $RELEASE_DIR"

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$RELEASE_DIR/PROVENANCE.md"
fi

if ! command -v jq >/dev/null 2>&1; then
    die "jq not on PATH"
fi

version="$(jq -r '.version' "$manifest")"
channel="$(jq -r '.channel' "$manifest")"
build_date="$(jq -r '.build_date' "$manifest")"
overlay_sha="$(jq -r '.commit_sha' "$manifest")"

tmp="$(mktemp)"
trap 'rm -f -- "$tmp"' EXIT

{
    printf '# airplanes.live runtime overlay release\n\n'
    printf '- Version: %s\n' "$version"
    printf '- Channel: %s\n' "$channel"
    printf '- Build date: %s\n' "$build_date"
    # SC2016: backticks here are intentional markdown formatting, not a
    # command-substitution syntax.
    # shellcheck disable=SC2016
    printf '- Overlay source commit: airplanes-live/image @ `%s`\n' "$overlay_sha"
    if [[ -n "$RUN_URL" ]]; then
        printf '- Workflow run: %s\n' "$RUN_URL"
    fi
    printf '\n'

    printf '## Component pins\n\n'
    # Sort alphabetically for byte-deterministic output.
    jq -r '.components | to_entries | sort_by(.key) | .[] | "- \(.key): `\(.value)`"' "$manifest"
    printf '\n'

    printf '## Upstream licenses\n\n'
    printf 'See each upstream repository for license texts:\n\n'
    printf '- readsb (wiedehopf fork): https://github.com/wiedehopf/readsb/blob/master/LICENSE\n'
    printf '- dump978-fa: https://github.com/flightaware/dump978/blob/master/COPYING\n'
    printf '- tar1090: https://github.com/wiedehopf/tar1090/blob/master/LICENSE\n'
    printf '- tar1090-db: https://github.com/wiedehopf/tar1090-db/blob/master/LICENSE\n'
    printf '- graphs1090: https://github.com/wiedehopf/graphs1090/blob/master/LICENSE\n'
    printf '\n'

    printf '## Verification\n\n'
    printf 'Verify the release before installing:\n\n'
    printf '```\n'
    printf 'minisign -V -p /usr/share/airplanes/runtime-release.pub \\\n'
    printf '         -x SHA256SUMS.minisig -m SHA256SUMS\n'
    printf 'sha256sum -c SHA256SUMS\n'
    printf '```\n'
} > "$tmp"

mv -f -- "$tmp" "$OUTPUT"
echo "write-provenance: wrote $OUTPUT"

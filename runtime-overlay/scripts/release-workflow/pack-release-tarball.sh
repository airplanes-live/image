#!/usr/bin/env bash
# pack-release-tarball.sh — wrap a v<X> release tree into a deterministic
# tar.gz. Uses GNU tar's reproducibility flags so two runs against the same
# tree produce byte-identical archives.
#
# Args:
#   --release-dir <path>     the v<X> directory to pack
#   --output <path>          target .tar.gz path
#   --mtime <YYYY-MM-DD HH:MM:SS UTC>  optional; defaults to '2024-01-01 00:00:00 UTC'

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: pack-release-tarball.sh \
    --release-dir <path> \
    --output <tarball.tar.gz> \
    [--mtime '<YYYY-MM-DD HH:MM:SS UTC>']
USAGE
}

die() {
    echo "pack-release-tarball: $*" >&2
    exit 1
}

RELEASE_DIR=""
OUTPUT=""
MTIME="2024-01-01 00:00:00 UTC"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release-dir) RELEASE_DIR="${2-}"; shift 2 ;;
        --output)      OUTPUT="${2-}";      shift 2 ;;
        --mtime)       MTIME="${2-}";       shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done

[[ -n "$RELEASE_DIR" ]] || { usage; die "missing --release-dir"; }
[[ -n "$OUTPUT" ]]      || { usage; die "missing --output"; }
[[ -d "$RELEASE_DIR" ]] || die "--release-dir not a directory: $RELEASE_DIR"

parent="$(dirname -- "$RELEASE_DIR")"
base="$(basename -- "$RELEASE_DIR")"

install -d -m 0755 "$(dirname -- "$OUTPUT")"

# Reproducible-build flags:
#   --sort=name            stable file order
#   --owner=0 --group=0    drop builder uid/gid from the archive
#   --numeric-owner        avoid host's /etc/passwd lookup
#   --mtime=<fixed>        pin mtime so SHA256SUMS over the tarball is stable
#   --pax-option=...time   strip per-file ctime/atime so newer GNU tar versions
#                          still emit deterministic output via pax extended hdrs
tmp="$(mktemp "$OUTPUT.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f -- '$tmp'" EXIT

tar --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="$MTIME" \
    --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
    -czf "$tmp" \
    -C "$parent" "$base"

mv -f -- "$tmp" "$OUTPUT"
trap - EXIT

echo "pack-release-tarball: wrote $OUTPUT"

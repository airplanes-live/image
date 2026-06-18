#!/usr/bin/env bash
# sudoers-managed-check.sh — verify that every command the staged sudoers
# files grant is one an on-device update actually provides.
#
# Why this gate exists: the sudoers grant and the helper it points at are
# authored in airplanes-live/image-webconfig, but what an in-place runtime
# overlay update lays down is decided by managed_paths (here, in
# airplanes-live/image). A new privileged helper shipped + granted in
# image-webconfig but missing a managed_paths entry here builds and FLASHES
# fine (the base rootfs carries it), yet a feeder UPDATED via the overlay
# receives the grant pointing at a path that was never linked into place —
# the privileged call then fails at runtime. (This is exactly how
# claim-rotate.sh slipped through.) Nothing else cross-checks the two repos'
# halves of that trust chain, so this gate is the guard.
#
# Rule: for every `NOPASSWD:` command path in any staged
# etc/sudoers.d/* file, the command must be either
#   - a base-OS binary under /usr/bin, /bin, /usr/sbin, or /sbin
#     (always present on the Debian rootfs, never the overlay's job), or
#   - provided by a managed_paths entry (an exact .link/.path, or under a
#     managed directory entry).
# Anything under /usr/local (or anywhere else) that no managed_paths entry
# provides fails the build.
#
# Args:
#   --release-dir <path>   the v<X> release tree (manifest.json + staged
#                          etc/sudoers.d/)

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: sudoers-managed-check.sh --release-dir <path-to-release-tree>
USAGE
}

die() {
    echo "sudoers-managed-check: $*" >&2
    exit 1
}

RELEASE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release-dir) RELEASE_DIR="${2-}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done

[[ -n "$RELEASE_DIR" ]] || { usage; die "missing --release-dir"; }
[[ -d "$RELEASE_DIR" ]] || die "--release-dir not a directory: $RELEASE_DIR"

manifest="$RELEASE_DIR/manifest.json"
[[ -f "$manifest" ]] || die "manifest not found: $manifest"
command -v jq >/dev/null || die "jq is required"

# Managed paths an on-device update guarantees to provide: every symlink
# .link and every copy .path.
mapfile -t MANAGED < <(jq -r '.managed_paths[]? | (.link // .path) // empty' "$manifest")

# is_provided <cmd-path> — true when the path is provided after an update:
# a base-OS bin, an exact managed entry, or under a managed directory entry.
is_provided() {
    local p="$1" m
    case "$p" in
        /usr/bin/*|/bin/*|/usr/sbin/*|/sbin/*) return 0 ;;
    esac
    for m in "${MANAGED[@]}"; do
        [[ "$p" == "$m" || "$p" == "$m/"* ]] && return 0
    done
    return 1
}

shopt -s nullglob
violations=0
checked=0
for sudoers in "$RELEASE_DIR"/etc/sudoers.d/*; do
    [[ -f "$sudoers" ]] || continue
    sudoers_name="$(basename "$sudoers")"
    while IFS= read -r line; do
        [[ "$line" == *NOPASSWD:* ]] || continue
        # Everything after NOPASSWD: is one or more comma-separated Cmnd
        # specs. Each spec may carry leading tags (e.g. SETENV:) before the
        # absolute command path, so take the first /-rooted token of each.
        spec="${line#*NOPASSWD:}"
        IFS=',' read -ra cmnds <<< "$spec"
        for c in "${cmnds[@]}"; do
            cmd=""
            for tok in $c; do
                if [[ "$tok" == /* ]]; then cmd="$tok"; break; fi
            done
            [[ -n "$cmd" ]] || continue
            checked=$((checked + 1))
            if ! is_provided "$cmd"; then
                echo "sudoers-managed-check: $sudoers_name grants '$cmd' but no managed_paths entry provides it — an updated feeder won't have it" >&2
                violations=$((violations + 1))
            fi
        done
    done < "$sudoers"
done

if (( violations > 0 )); then
    die "$violations sudoers grant(s) reference a path the overlay update does not provide; add a managed_paths entry (or, for a base-OS binary, confirm its location)"
fi

echo "sudoers-managed-check: OK ($checked granted command(s) all provided by managed_paths or the base OS)"

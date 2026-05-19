#!/usr/bin/env bash
# verify-gates.sh — orchestrator that runs every release gate against a
# v<X> release tree. Exists so the workflow YAML stays short and each gate
# can be invoked individually from a developer machine.
#
# Args:
#   --release-dir <path>    the v<X> release tree
#   --channel <stable|dev>  release channel (drives migration-pair-check's
#                           cross-release id-uniqueness lookup)
#
# Gates run, in order:
#   1. validate-manifest.sh on <release-dir>/manifest.json
#   2. systemd-verify.sh
#   3. lighttpd-verify.sh
#   4. migration-pair-check.sh
#   5. shellcheck -x over staged share/airplanes/*.sh
#   6. ldd over cross-compiled binaries — no `not found` lines

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
gates_dir="$_self_dir/../gates"
validate_manifest="$_self_dir/../validate-manifest.sh"

usage() {
    cat >&2 <<'USAGE'
usage: verify-gates.sh --release-dir <path> --channel <stable|dev>
USAGE
}

die() {
    echo "verify-gates: $*" >&2
    exit 1
}

RELEASE_DIR=""
CHANNEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release-dir) RELEASE_DIR="${2-}"; shift 2 ;;
        --channel)     CHANNEL="${2-}";     shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done

[[ -n "$RELEASE_DIR" ]] || { usage; die "missing --release-dir"; }
[[ -n "$CHANNEL" ]]     || { usage; die "missing --channel"; }
[[ -d "$RELEASE_DIR" ]] || die "--release-dir not a directory: $RELEASE_DIR"

echo "verify-gates: validate-manifest"
"$validate_manifest" "$RELEASE_DIR/manifest.json"

echo "verify-gates: systemd-verify"
"$gates_dir/systemd-verify.sh" --release-dir "$RELEASE_DIR"

echo "verify-gates: lighttpd-verify"
"$gates_dir/lighttpd-verify.sh" --release-dir "$RELEASE_DIR"

echo "verify-gates: migration-pair-check"
"$gates_dir/migration-pair-check.sh" --release-dir "$RELEASE_DIR" --channel "$CHANNEL"

echo "verify-gates: shellcheck staged share/airplanes/*.sh"
shopt -s nullglob
shell_files=("$RELEASE_DIR/share/airplanes"/*.sh)
shopt -u nullglob
if [[ "${#shell_files[@]}" -gt 0 ]]; then
    shellcheck -x "${shell_files[@]}"
else
    echo "verify-gates: no share/airplanes/*.sh files to shellcheck (ok)"
fi

echo "verify-gates: ldd cross-compiled binaries"
shopt -s nullglob
bins=("$RELEASE_DIR/bin"/*)
shopt -u nullglob
for b in "${bins[@]}"; do
    # Skip subdirs / non-ELF — `file` is cheap and tells us what's an ELF.
    if file -bL "$b" 2>/dev/null | grep -q 'ELF'; then
        if ldd "$b" 2>&1 | grep -q 'not found'; then
            {
                echo "verify-gates: $b has unresolved shared libraries:"
                ldd "$b" | grep 'not found' || true
            } >&2
            exit 1
        fi
    fi
done

echo "verify-gates: ok"

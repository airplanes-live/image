#!/usr/bin/env bash
# systemd-verify.sh — run `systemd-analyze verify` against every .service /
# .path / .timer unit shipped in a runtime-overlay release tree.
#
# Why a wrapper: the staged tree's units use absolute on-device paths
# (/usr/local/share/airplanes/..., /usr/local/bin/...) that won't exist on
# the runner. We materialize stub binaries at those paths inside a temporary
# --root and let systemd-analyze validate ExecStart= resolution against the
# stubs. Drift in unit syntax / cycle introduction still surfaces; missing
# stub-paths surface as a "unit not found"-class warning which we treat as
# non-fatal via --recursive-errors=no, matching the existing ci.yml
# `systemd-verify` job.
#
# Args:
#   --release-dir <path>   the v<X> release tree to verify
#
# Behaviour:
#   - Discovers every .service / .path / .timer under <release-dir>/systemd/.
#   - Sets up a scratch root containing only those units + stubs for every
#     absolute path referenced in ExecStart=/ExecStartPre=/ExecStartPost=.
#   - Invokes `systemd-analyze verify --root=<scratch> --recursive-errors=no
#     <units...>`.
#   - Exits 0 iff every unit verifies cleanly.

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: systemd-verify.sh --release-dir <path-to-release-tree>
USAGE
}

die() {
    echo "systemd-verify: $*" >&2
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
[[ -d "$RELEASE_DIR" ]] || die "release dir not a directory: $RELEASE_DIR"

systemd_dir="$RELEASE_DIR/systemd"
[[ -d "$systemd_dir" ]] || die "no systemd/ subtree under $RELEASE_DIR"

shopt -s nullglob
units=("$systemd_dir"/*.service "$systemd_dir"/*.path "$systemd_dir"/*.timer)
shopt -u nullglob

if [[ "${#units[@]}" -eq 0 ]]; then
    die "no .service / .path / .timer files under $systemd_dir"
fi

if ! command -v systemd-analyze >/dev/null 2>&1; then
    die "systemd-analyze not on PATH (install systemd)"
fi

scratch="$(mktemp -d -t systemd-verify.XXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT

install -d -m 0755 "$scratch/etc/systemd/system"

# Copy units into the scratch root.
unit_basenames=()
for unit in "${units[@]}"; do
    install -m 0644 "$unit" "$scratch/etc/systemd/system/"
    unit_basenames+=("$(basename -- "$unit")")
done

# Walk ExecStart=/ExecStartPre=/ExecStartPost= for absolute paths and stub
# every binary it references so systemd-analyze does not flag a missing exec.
# We do NOT try to be clever about shell metacharacters — the regex anchors
# on a leading '/' and gives up at the first space, which matches what
# systemd's own parser reads as the binary path. Unit authors who use
# `ExecStart=-/path` (allowed) are handled by stripping a leading `-`.
stub_paths=()
while IFS= read -r line; do
    raw="${line#*=}"
    # Strip leading sign-flags ('-', '!', '!!', '+', ':', '@', '|') that
    # systemd accepts on ExecStart=. Order-independent loop.
    while [[ -n "$raw" && "${raw:0:1}" =~ [-!\+:@\|] ]]; do
        raw="${raw:1}"
    done
    bin_path="${raw%% *}"
    [[ "$bin_path" == /* ]] || continue
    stub_paths+=("$bin_path")
done < <(grep -hE '^[[:space:]]*Exec(Start|StartPre|StartPost|Stop|StopPost|Reload)=' \
                "${units[@]}" || true)

# Stub every referenced binary as a 0755 empty file under the scratch root.
# `systemd-analyze --root` resolves ExecStart= relative to <root>, so stubs
# laid down here satisfy the path-exists check without requiring the actual
# binary semantics.
for p in "${stub_paths[@]}"; do
    target="$scratch$p"
    install -d -m 0755 "$(dirname -- "$target")"
    : > "$target"
    chmod 0755 "$target"
done

# EnvironmentFile= references — best-effort empty stubs so verify doesn't
# warn about missing env files for the on-device defaults dirs.
while IFS= read -r line; do
    raw="${line#*=}"
    while [[ -n "$raw" && "${raw:0:1}" =~ [-!\+:@\|] ]]; do
        raw="${raw:1}"
    done
    env_path="${raw%% *}"
    [[ "$env_path" == /* ]] || continue
    target="$scratch$env_path"
    install -d -m 0755 "$(dirname -- "$target")"
    [[ -e "$target" ]] || : > "$target"
done < <(grep -hE '^[[:space:]]*EnvironmentFile=' "${units[@]}" || true)

# Run verify. --recursive-errors=no mirrors the existing ci.yml job's gate
# posture: cycle / syntax errors fail; missing external targets do not.
echo "systemd-verify: scratch root at $scratch"
echo "systemd-verify: verifying ${#unit_basenames[@]} units"
systemd-analyze verify --root="$scratch" --recursive-errors=no "${unit_basenames[@]}"

echo "systemd-verify: ok"

#!/usr/bin/env bash
# exec-bit-check.sh — verify that every file in the staged release tree
# that's expected to be executable actually is.
#
# Why this gate exists: a packaging regression where the source-tree
# .sh files were committed at 0644 caused
# airplanes-runtime-update-recover.service to fail at boot with
# `203/EXEC` because the script behind its ExecStart= was not
# executable. systemd-analyze verify does not catch this — its scratch
# root writes stub binaries at 0755 regardless of the real mode in the
# release tarball.
#
# Coverage:
#   1. Every managed_paths[].target under bin/, lib/* scripts, scripts
#      ending in .sh under share/airplanes/, or anything under
#      etc/update-motd.d/ must exist in the staged tree, be a regular
#      file, have at least one execute bit set, and (for files ending
#      in .sh) start with `#!` and contain no CRLF in the shebang line.
#   2. Every ExecStart=/ExecStartPre=/ExecStartPost=/ExecStop=/
#      ExecStopPost=/ExecReload= absolute path referenced by a unit in
#      the staged tree, whose path resolves into the release tree
#      (either directly under /opt/airplanes-runtime/current/ or via a
#      managed_paths symlink), must satisfy the same shape constraints.
#
# Mode check is "regular file + any execute bit", not exact 0755. Git
# tracks executability as a single bit; staged provenance (cp -a from
# wiedehopf source trees, install -m, etc.) can land 0775. Requiring an
# exact mask creates false failures.
#
# Args:
#   --release-dir <path>   the v<X> release tree

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: exec-bit-check.sh --release-dir <path-to-release-tree>
USAGE
}

die() {
    echo "exec-bit-check: $*" >&2
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

command -v jq >/dev/null 2>&1 || die "jq is required"

manifest="$RELEASE_DIR/manifest.json"
[[ -f "$manifest" ]] || die "manifest.json missing under $RELEASE_DIR"

CURRENT_PREFIX="/opt/airplanes-runtime/current/"

# Build a lookup from on-device absolute path -> release-local path for
# every managed_paths symlink entry. This is how an ExecStart= that
# names /usr/local/share/airplanes/readsb.sh maps back to the
# release-local share/airplanes/readsb.sh file we need to check.
declare -A managed_link_to_release_local=()
while IFS=$'\t' read -r link target; do
    [[ -z "$link" || -z "$target" ]] && continue
    [[ "$target" == "$CURRENT_PREFIX"* ]] || continue
    managed_link_to_release_local["$link"]="${target#"$CURRENT_PREFIX"}"
done < <(jq -r '.managed_paths[]? | select(.mode == "symlink") | [.link, .target] | @tsv' "$manifest")

# A release-local path "looks executable" if it lives under bin/, is a
# .sh under share/airplanes/, is the render-status binary or lives
# under lib/airplanes/, sits under etc/update-motd.d/, or is a .sh
# under lib/ (the runtime self-update helpers).
_should_be_executable() {
    local rel="$1"
    case "$rel" in
        bin/*)                          return 0 ;;
        share/airplanes/*.sh)           return 0 ;;
        lib/airplanes/render-status)    return 0 ;;
        lib/airplanes/*)                return 0 ;;
        lib/*.sh)                       return 0 ;;
        etc/update-motd.d/*)            return 0 ;;
        scripts/lib/*.sh)               return 0 ;;
        scripts/release-workflow/*.sh)  return 0 ;;
        scripts/gates/*.sh)             return 0 ;;
        scripts/validate-manifest.sh)   return 0 ;;
        scripts/build-release.sh)       return 0 ;;
    esac
    return 1
}

# Assert one staged-tree-relative file: present, regular, executable.
# For .sh / scripts, also assert a valid `#!` on line 1 with no CRLF.
# Returns 1 on failure with a diagnostic on stderr (does NOT `die`).
# Earlier shape called `die` inside this function and exited the script
# on the first failure; the calling site's `2>/tmp/...` stderr capture
# meant the operator saw no error message in the GH Actions log. Returning
# non-zero lets the caller aggregate failures and print every one.
_assert_exec_file() {
    local rel="$1" referer="$2"
    local abs="$RELEASE_DIR/$rel"
    if [[ ! -e "$abs" ]]; then
        echo "exec-bit-check: missing file referenced by $referer: release_dir/$rel (does not exist)" >&2
        return 1
    fi
    if [[ ! -f "$abs" ]]; then
        echo "exec-bit-check: $referer points at non-regular file: release_dir/$rel" >&2
        return 1
    fi
    # `[[ -x ]]` fails when no execute bit is set. Cheaper than a
    # stat-and-mask, and accepts 0700/0750/0755/0775 alike.
    if [[ ! -x "$abs" ]]; then
        local mode
        mode="$(stat -c '%a' -- "$abs" 2>/dev/null || echo '???')"
        echo "exec-bit-check: $referer points at non-executable file: release_dir/$rel (mode=$mode; needs at least one execute bit)" >&2
        return 1
    fi
    # Shebang + CRLF guard for shell scripts. A `0755` file with no
    # shebang fails execve identically to a 0644 file; this is the
    # same class of bug from a different angle.
    # `*.sh` already covers lib/*.sh and share/airplanes/*.sh; keep the
    # extra branches for the render-status binary (no extension) and a
    # future `.bash` file. Order matters — shellcheck's SC2221 flags
    # redundant subset patterns, so the broader `*.sh` lives first and
    # the narrower script paths only need to enumerate what `*.sh`
    # doesn't reach.
    case "$rel" in
        *.sh|*.bash|lib/airplanes/render-status)
            local first_two
            first_two="$(LC_ALL=C head -c 2 -- "$abs" 2>/dev/null)"
            if [[ "$first_two" != "#!" ]]; then
                echo "exec-bit-check: $referer points at script without #! shebang on line 1: release_dir/$rel (first two bytes: $(printf '%q' "$first_two"))" >&2
                return 1
            fi
            # CRLF in shebang line crashes execve with
            # ENOEXEC / "bad interpreter: no such file or directory"
            # because the kernel passes the trailing \r as part of the
            # interpreter argv. Cheap to assert here.
            local first_line
            first_line="$(LC_ALL=C head -n 1 -- "$abs" 2>/dev/null)"
            if [[ "$first_line" == *$'\r'* ]]; then
                echo "exec-bit-check: $referer shebang line contains CR (CRLF line ending): release_dir/$rel — kernel will reject execve" >&2
                return 1
            fi
            ;;
    esac
    return 0
}

# --- managed_paths shape gate --------------------------------------------

# Every managed_paths[].target whose release-local source path "looks
# executable" must satisfy the exec-file shape.
fail_count=0
while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if _should_be_executable "$rel"; then
        if ! _assert_exec_file "$rel" "managed_paths target"; then
            fail_count=$((fail_count + 1))
        fi
    fi
done < <(jq -r '.managed_paths[]? | select(.mode == "symlink") | .target' "$manifest" \
            | awk -v p="$CURRENT_PREFIX" 'index($0, p) == 1 { print substr($0, length(p) + 1) }')

# --- ExecStart references gate -------------------------------------------

# Walk every unit in the staged systemd/ tree, parse Exec*= absolute
# paths, and assert any path that resolves into the release tree is
# executable. Resolution is:
#   - Direct: path starts with /opt/airplanes-runtime/current/<rel>
#       -> release-local <rel>
#   - Indirect: path is a managed_paths[].link whose target starts with
#     /opt/airplanes-runtime/current/<rel> -> release-local <rel>
#   - Otherwise: out of scope (host-installed binary like /usr/bin/apt-get).
systemd_dir="$RELEASE_DIR/systemd"
if [[ -d "$systemd_dir" ]]; then
    shopt -s nullglob
    units=("$systemd_dir"/*.service "$systemd_dir"/*.path "$systemd_dir"/*.timer)
    shopt -u nullglob

    for unit in "${units[@]}"; do
        unit_base="$(basename -- "$unit")"
        while IFS= read -r line; do
            raw="${line#*=}"
            # systemd accepts leading sign-flags on Exec*= lines:
            # `-`, `!`, `!!`, `+`, `:`, `@`, `|`. Strip them all so
            # the binary path is what's left at the head.
            while [[ -n "$raw" && "${raw:0:1}" =~ [-!\+:@\|] ]]; do
                raw="${raw:1}"
            done
            bin_path="${raw%% *}"
            [[ "$bin_path" == /* ]] || continue

            rel=""
            if [[ "$bin_path" == "$CURRENT_PREFIX"* ]]; then
                rel="${bin_path#"$CURRENT_PREFIX"}"
            elif [[ -n "${managed_link_to_release_local[$bin_path]:-}" ]]; then
                rel="${managed_link_to_release_local[$bin_path]}"
            else
                # Host-installed binary; out of scope.
                continue
            fi

            if ! _assert_exec_file "$rel" "$unit_base Exec=$bin_path"; then
                fail_count=$((fail_count + 1))
            fi
        done < <(grep -hE '^[[:space:]]*Exec(Start|StartPre|StartPost|Stop|StopPost|Reload)=' \
                    "$unit" 2>/dev/null || true)
    done
fi

if (( fail_count > 0 )); then
    die "$fail_count file(s) failed the executable-bit / shebang shape check"
fi

echo "exec-bit-check: ok"

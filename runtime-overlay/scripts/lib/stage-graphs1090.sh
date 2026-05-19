#!/usr/bin/env bash
# stage-graphs1090.sh — run graphs1090's install.sh against a scratch sysroot
# and stage the produced files into a release-tree-shaped output dir.
#
# Mirrors `stage-airplanes/04-install-graphs1090/01-run-chroot.sh` modulo
# the chroot context. We additionally apply the URL_978 + Interface
# normalization edits to /etc/collectd/collectd.conf at staging time so the
# release tarball ships the corrected file (legacy stage 04 applies these
# edits in-chroot; runtime-overlay applies them here once, releases later).
#
# Args:
#   --repo <git-url>
#   --ref <sha-or-branch>
#   --output-dir <staging-dir>
#
# What gets staged (under <output-dir>):
#   share/graphs1090/                            $ipath tree install.sh produces
#   share/graphs1090/978-symlink/.gitkeep        directory placeholder; the
#                                                inner data symlink to
#                                                /run/airplanes-978 is
#                                                runtime-only
#   systemd/graphs1090.service                   the unit (paths are
#                                                /usr/share/graphs1090, which
#                                                is symlinked from the runtime
#                                                overlay on-device)
#   etc/lighttpd/conf-available/88-graphs1090.conf
#   etc/collectd/collectd.conf                   POST URL_978 + Interface
#                                                edits — already corrected
#                                                in the release tarball
#   components.graphs1090.sha
#
# collectd's unit is NOT shipped — collectd is an apt-installed package on
# the feeder. The runtime-overlay manifest's systemd.enable list calls
# `systemctl enable collectd` against the package's own unit file.
#
# Dependency: bubblewrap (`bwrap`) must be on PATH.

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

usage() {
    cat >&2 <<'USAGE'
usage: stage-graphs1090.sh \
    --repo <git-url> \
    --ref <sha-or-branch> \
    --output-dir <staging-dir>
USAGE
}

die() {
    echo "stage-graphs1090: $*" >&2
    exit 1
}

REPO=""
REF=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        REPO="${2-}";        shift 2 ;;
        --ref)         REF="${2-}";         shift 2 ;;
        --output-dir)  OUTPUT_DIR="${2-}";  shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; echo "stage-graphs1090: unknown argument: $1" >&2; exit 2 ;;
    esac
done

for required in REPO REF OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        echo "stage-graphs1090: missing required --$flag" >&2
        exit 2
    fi
done

if ! command -v bwrap >/dev/null 2>&1; then
    die "bubblewrap (bwrap) is required; install via 'apt-get install bubblewrap'"
fi

is_full_sha() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

fetch_repo() {
    local dir="$1" repo="$2" ref="$3"
    rm -rf -- "$dir"
    install -d -m 0755 "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$repo"
    if is_full_sha "$ref"; then
        if ! git -C "$dir" fetch --depth 1 origin "$ref" 2>/dev/null; then
            git -C "$dir" fetch origin
        fi
    else
        git -C "$dir" fetch --depth 1 origin "$ref"
    fi
    git -C "$dir" checkout -q FETCH_HEAD
}

SCRATCH_DIR="$(mktemp -d -t stage-graphs1090.XXXXXX)"
# shellcheck disable=SC2064
trap 'rm -rf -- "$SCRATCH_DIR"' EXIT

BUILD_DIR="$SCRATCH_DIR/graphs1090-src"
fetch_repo "$BUILD_DIR" "$REPO" "$REF"
GRAPHS1090_SHA="$(git -C "$BUILD_DIR" rev-parse HEAD)"

# graphs1090 install.sh writes to these absolute paths; all must be backed
# by sysroot trees we control. $ipath is hardcoded /usr/share/graphs1090.
SYSROOT="$SCRATCH_DIR/sysroot"
IPATH_ABS="/usr/share/graphs1090"
install -d -m 0755 \
    "$SYSROOT$IPATH_ABS" \
    "$SYSROOT/etc/collectd" \
    "$SYSROOT/etc/lighttpd/conf-available" \
    "$SYSROOT/etc/lighttpd/conf-enabled" \
    "$SYSROOT/etc/default" \
    "$SYSROOT/lib/systemd/system" \
    "$SYSROOT/var/lib/graphs1090" \
    "$SYSROOT/var/lib/collectd" \
    "$SYSROOT/run/collectd"

# Empty stub so install.sh's sed edits against lighttpd.conf no-op cleanly.
: > "$SYSROOT/etc/lighttpd/lighttpd.conf"

# Stubs for the few commands install.sh calls that should not touch the
# host. graphs1090's install.sh has an explicit `pkill -9 collectd` per
# its python-version detection workflow — stage 04 stubs this exactly for
# this reason (the host's /proc is visible to the chroot, so an un-stubbed
# pkill would target real host processes). bwrap shares /proc with the
# host, so we keep the stub.
SHIM_BIN="$SCRATCH_DIR/shim-bin"
install -d -m 0755 "$SHIM_BIN"
for cmd in systemctl pkill service; do
    {
        printf '#!/bin/sh\n'
        printf 'echo "%s stub (stage-graphs1090): $*" >&2\n' "$cmd"
        printf 'exit 0\n'
    } > "$SHIM_BIN/$cmd"
    chmod 0755 "$SHIM_BIN/$cmd"
done

PATH_IN="$SHIM_BIN:/usr/bin:/bin"

# Bind all paths install.sh touches. Read-only everywhere else.
# --unshare-pid: graphs1090's install.sh detects the python version by
# running `collectd 2>&1 | grep ...`. Per upstream's own comment that
# invocation can leave a daemonized collectd running. Without an isolated
# PID namespace the leak would survive the bwrap exit and accumulate on
# the host (stage 04 has the same pitfall — stage 07 reaps these in the
# legacy build context). An isolated PID namespace makes the leaked
# process die when bwrap tears down, no host-side reaper needed.
bwrap \
    --unshare-pid \
    --ro-bind / / \
    --dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --bind "$SYSROOT$IPATH_ABS"             "$IPATH_ABS" \
    --bind "$SYSROOT/etc/collectd"          /etc/collectd \
    --bind "$SYSROOT/etc/lighttpd"          /etc/lighttpd \
    --bind "$SYSROOT/etc/default"           /etc/default \
    --bind "$SYSROOT/lib/systemd/system"    /lib/systemd/system \
    --bind "$SYSROOT/var/lib/graphs1090"    /var/lib/graphs1090 \
    --bind "$SYSROOT/var/lib/collectd"      /var/lib/collectd \
    --bind "$SYSROOT/run/collectd"          /run/collectd \
    --bind "$BUILD_DIR"                     "$BUILD_DIR" \
    --setenv PATH "$PATH_IN" \
    --chdir "$BUILD_DIR" \
    -- bash "$BUILD_DIR/install.sh" test \
    || die "graphs1090 install.sh failed under bwrap"

# --- collect staging tree --------------------------------------------------

install -d -m 0755 \
    "$OUTPUT_DIR/share/graphs1090" \
    "$OUTPUT_DIR/etc/lighttpd/conf-available" \
    "$OUTPUT_DIR/etc/collectd" \
    "$OUTPUT_DIR/systemd"

# Drop the install.sh-cached git/ working tree under $ipath if present.
# 02-run.sh in stage 04 deletes $ipath/git unconditionally for the same
# reason — runtime never reads from it.
rm -rf -- "$SYSROOT$IPATH_ABS/git" || true

cp -a "$SYSROOT$IPATH_ABS/." "$OUTPUT_DIR/share/graphs1090/"

# graphs1090 install creates `978-symlink/data` as a runtime symlink to a
# /run/ path. The symlink target doesn't exist at staging time, but the
# dir DOES — install.sh `mkdir -p`s it and `ln -sfn`s the inner data link.
# The release tarball needs the directory to exist on extract so the
# on-device runtime can re-link `data` after unpacking. cp -a above
# preserved both the directory and the dangling symlink; assert.
if [[ ! -d "$OUTPUT_DIR/share/graphs1090/978-symlink" ]]; then
    # Defensive fallback: if install.sh skipped the mkdir for some reason,
    # create it so the runtime install.sh's symlink-target check has a
    # stable parent. The on-device install creates the inner `data` link
    # pointing at /run/airplanes-978.
    install -d -m 0755 "$OUTPUT_DIR/share/graphs1090/978-symlink"
    : > "$OUTPUT_DIR/share/graphs1090/978-symlink/.gitkeep"
fi

# Capture the systemd unit.
GRAPHS1090_UNIT="$SYSROOT/lib/systemd/system/graphs1090.service"
[[ -f "$GRAPHS1090_UNIT" ]] \
    || die "graphs1090 install did not produce $GRAPHS1090_UNIT"
cp -a "$GRAPHS1090_UNIT" "$OUTPUT_DIR/systemd/graphs1090.service"

# Capture lighttpd snippet.
LIGHTTPD_SRC="$SYSROOT/etc/lighttpd/conf-available"
[[ -f "$LIGHTTPD_SRC/88-graphs1090.conf" ]] \
    || die "graphs1090 install did not produce $LIGHTTPD_SRC/88-graphs1090.conf"
cp -a "$LIGHTTPD_SRC/88-graphs1090.conf" \
    "$OUTPUT_DIR/etc/lighttpd/conf-available/88-graphs1090.conf"

# --- apply collectd.conf edits at staging time -----------------------------

# graphs1090's install.sh writes /etc/collectd/collectd.conf as a template.
# Legacy stage 04 then sed-edits it in-chroot to (a) replace the commented
# URL_978 line with a concrete file URL pointing at our 978-symlink, and
# (b) normalize the <Plugin "interface"> block's Interface lines to the
# canonical Pi set. Applying the edits at staging time means the release
# tarball ships the already-corrected file — no per-install fixup needed.
#
# Order is deterministic: URL_978 first, then Interface normalization.
# Both operations are idempotent; running them in either order yields the
# same output. The fixed sequence keeps the diff against the legacy stage
# trivial to audit.
STAGED_COLLECTD="$OUTPUT_DIR/etc/collectd/collectd.conf"
[[ -f "$SYSROOT/etc/collectd/collectd.conf" ]] \
    || die "graphs1090 install did not produce /etc/collectd/collectd.conf in sysroot"
cp -a "$SYSROOT/etc/collectd/collectd.conf" "$STAGED_COLLECTD"

# URL_978 edit. Match stage 04's sed exactly.
sed -i -E 's|^[[:space:]]*#[[:space:]]*URL_978 .*|URL_978 "file:///usr/share/graphs1090/978-symlink"|' \
    "$STAGED_COLLECTD"

# Interface normalization. Match stage 04's awk exactly. The block-rewrite
# pattern is: when entering the <Plugin "interface"> block, immediately
# emit the three canonical Pi interface names; suppress any subsequent
# Interface "..." lines until the closing </Plugin>.
COLLECTD_TMP="$SCRATCH_DIR/collectd.conf.new"
awk '
/^<Plugin "interface">$/ { in_block=1; print; print "    Interface \"eth0\""; print "    Interface \"end0\""; print "    Interface \"wlan0\""; next }
in_block && /^<\/Plugin>/ { in_block=0; print; next }
in_block && /^[[:space:]]*Interface ".*"/ { next }
{ print }
' "$STAGED_COLLECTD" > "$COLLECTD_TMP"
mv -f "$COLLECTD_TMP" "$STAGED_COLLECTD"

# --- collectd.service ------------------------------------------------------

# Note on collectd.service: graphs1090's install.sh does NOT write a collectd
# unit file. collectd ships as an apt package on the feeder, and the
# runtime overlay manifest's systemd.enable list just enables the package's
# /lib/systemd/system/collectd.service. Nothing to stage here from the
# graphs1090 source tree.

# --- path-relocatability check --------------------------------------------

LEAK_HITS="$( \
    { \
        grep -RFnH -- "$SYSROOT" \
            "$OUTPUT_DIR/share/graphs1090" \
            "$OUTPUT_DIR/systemd" \
            "$OUTPUT_DIR/etc/lighttpd" \
            "$OUTPUT_DIR/etc/collectd" \
            2>/dev/null || true; \
        grep -RFnH -- "$SCRATCH_DIR" \
            "$OUTPUT_DIR/share/graphs1090" \
            "$OUTPUT_DIR/systemd" \
            "$OUTPUT_DIR/etc/lighttpd" \
            "$OUTPUT_DIR/etc/collectd" \
            2>/dev/null || true; \
    } | grep -E '\.(sh|py|service|conf)(:|$)' || true \
)"
if [[ -n "$LEAK_HITS" ]]; then
    {
        echo "stage-graphs1090: scratch/sysroot path leaked into staged tree:"
        echo "$LEAK_HITS"
    } >&2
    exit 1
fi

# --- lighttpd syntax check ------------------------------------------------

if command -v lighttpd >/dev/null 2>&1; then
    HARNESS="$SCRATCH_DIR/lighttpd-harness.conf"
    {
        echo 'server.document-root = "/tmp"'
        echo 'server.modules = ( "mod_alias", "mod_setenv" )'
        printf 'include "%s"\n' \
            "$OUTPUT_DIR/etc/lighttpd/conf-available/88-graphs1090.conf"
    } > "$HARNESS"
    if ! lighttpd -tt -f "$HARNESS" >/dev/null 2>&1; then
        {
            echo "stage-graphs1090: lighttpd -tt rejected 88-graphs1090.conf:"
            lighttpd -tt -f "$HARNESS" || true
        } >&2
        exit 1
    fi
fi

# --- pin record -----------------------------------------------------------

printf '%s\n' "$GRAPHS1090_SHA" > "$OUTPUT_DIR/components.graphs1090.sha"

echo "stage-graphs1090: staged graphs1090 $GRAPHS1090_SHA"

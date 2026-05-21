#!/usr/bin/env bash
# stage-graphs1090.sh — run graphs1090's install.sh against a scratch sysroot
# and stage the produced files into a release-tree-shaped output dir.
#
# We additionally apply the URL_978 + Interface normalization edits to
# /etc/collectd/collectd.conf at staging time so the release tarball ships
# the corrected file.
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
# lighttpd must be on PATH so graphs1090's install.sh produces the
# 88-graphs1090.conf snippet we stage. Without it the release would
# ship no lighttpd alias for /graphs1090/.
if ! command -v lighttpd >/dev/null 2>&1; then
    die "lighttpd is required so graphs1090's install.sh emits the lighttpd snippet; install via 'apt-get install lighttpd'"
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
# install.sh also calls malarky.sh (unless $ipath/noMalarky exists), which
# writes to /etc/systemd/system/collectd.service.d/ and /etc/cron.d/.
# Legacy stage 04 lets malarky.sh run uncontested, so the released image
# carries those outputs; we mirror that behaviour for runtime-overlay
# parity. Bind the extra targets so the writes land in sysroot.
SYSROOT="$SCRATCH_DIR/sysroot"
IPATH_ABS="/usr/share/graphs1090"
install -d -m 0755 \
    "$SYSROOT$IPATH_ABS" \
    "$SYSROOT/etc/collectd" \
    "$SYSROOT/etc/lighttpd/conf-available" \
    "$SYSROOT/etc/lighttpd/conf-enabled" \
    "$SYSROOT/etc/default" \
    "$SYSROOT/etc/cron.d" \
    "$SYSROOT/etc/systemd/system" \
    "$SYSROOT/etc/systemd/system/collectd.service.d" \
    "$SYSROOT/lib/systemd/system" \
    "$SYSROOT/var/lib/graphs1090" \
    "$SYSROOT/var/lib/collectd" \
    "$SYSROOT/run/collectd"

# install.sh sed-edits lighttpd.conf AND validates with `lighttpd -tt -f`.
# An empty stub fails validation. Copy the host's Debian-default conf as a
# known-parseable starting point.
if [[ -r /etc/lighttpd/lighttpd.conf ]]; then
    cp /etc/lighttpd/lighttpd.conf "$SYSROOT/etc/lighttpd/lighttpd.conf"
else
    die "/etc/lighttpd/lighttpd.conf not readable on host — lighttpd package not installed?"
fi

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

PATH_IN="$SHIM_BIN:/usr/sbin:/usr/bin:/sbin:/bin"

# Pre-create bind mountpoints on the host. With `--ro-bind / /`, bwrap
# cannot mkdir its own mountpoint dirs inside the read-only root, so any
# bind target that does not already exist on the host (graphs1090's
# install dir, the per-service /var/lib and /run dirs, /etc/collectd on
# a runner without collectd-core apt-installed) trips bwrap with
# "Can't mkdir ...: Read-only file system". The dirs are empty
# placeholders; bwrap mounts SYSROOT subdirs over them.
ensure_mountpoint() {
    local p
    for p in "$@"; do
        if [[ -d "$p" ]]; then continue; fi
        if mkdir -p "$p" 2>/dev/null; then continue; fi
        sudo mkdir -p "$p" || die "could not create bind mountpoint $p (need root or sudo)"
    done
}
ensure_mountpoint \
    "$IPATH_ABS" \
    /etc/collectd \
    /var/lib/graphs1090 \
    /var/lib/collectd \
    /run/collectd

# Bind all paths install.sh touches. Read-only everywhere else.
# --unshare-pid: graphs1090's install.sh detects the python version by
# running `collectd 2>&1 | grep ...`. Per upstream's own comment that
# invocation can leave a daemonized collectd running. Without an isolated
# PID namespace the leak would survive the bwrap exit and accumulate on
# the host (stage 04 has the same pitfall — stage 07 reaps these in the
# legacy build context). An isolated PID namespace makes the leaked
# process die when bwrap tears down, no host-side reaper needed.
#
# SHIM_BIN sits under SCRATCH_DIR which is under /tmp; the --tmpfs /tmp
# above masks it inside the sandbox. Bind it through so PATH lookup
# against $SHIM_BIN resolves and the stubbed useradd/adduser/systemctl
# actually run from the install.sh's perspective.
bwrap \
    --unshare-pid \
    --ro-bind / / \
    --dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --bind "$SYSROOT$IPATH_ABS"                            "$IPATH_ABS" \
    --bind "$SYSROOT/etc/collectd"                         /etc/collectd \
    --bind "$SYSROOT/etc/lighttpd"                         /etc/lighttpd \
    --bind "$SYSROOT/etc/default"                          /etc/default \
    --bind "$SYSROOT/etc/cron.d"                           /etc/cron.d \
    --bind "$SYSROOT/etc/systemd/system"                   /etc/systemd/system \
    --bind "$SYSROOT/lib/systemd/system"                   /lib/systemd/system \
    --bind "$SYSROOT/var/lib/graphs1090"                   /var/lib/graphs1090 \
    --bind "$SYSROOT/var/lib/collectd"                     /var/lib/collectd \
    --bind "$SYSROOT/run/collectd"                         /run/collectd \
    --ro-bind "$SHIM_BIN"                                  "$SHIM_BIN" \
    --bind "$BUILD_DIR"                                    "$BUILD_DIR" \
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
    # Non-hidden placeholder so actions/upload-artifact (which drops
    # hidden files by default) retains the otherwise-empty directory.
    # The on-device install replaces the inner `data` link at first boot;
    # this marker can stay alongside it harmlessly.
    : > "$OUTPUT_DIR/share/graphs1090/978-symlink/KEEP"
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
# Apply two edits at staging time so the release tarball ships the
# already-corrected file: (a) replace the commented URL_978 line with a
# concrete file URL pointing at our 978-symlink, and (b) normalize the
# <Plugin "interface"> block's Interface lines to the canonical Pi set.
#
# Order is deterministic: URL_978 first, then Interface normalization. Both
# operations are idempotent; running them in either order yields the same
# output.
STAGED_COLLECTD="$OUTPUT_DIR/etc/collectd/collectd.conf"
[[ -f "$SYSROOT/etc/collectd/collectd.conf" ]] \
    || die "graphs1090 install did not produce /etc/collectd/collectd.conf in sysroot"
cp -a "$SYSROOT/etc/collectd/collectd.conf" "$STAGED_COLLECTD"

# URL_978 edit.
sed -i -E 's|^[[:space:]]*#[[:space:]]*URL_978 .*|URL_978 "file:///usr/share/graphs1090/978-symlink"|' \
    "$STAGED_COLLECTD"

# Interface normalization. The block-rewrite pattern is: when entering the
# <Plugin "interface"> block, immediately emit the three canonical Pi
# interface names; suppress any subsequent Interface "..." lines until the
# closing </Plugin>.
COLLECTD_TMP="$SCRATCH_DIR/collectd.conf.new"
awk '
/^<Plugin "interface">$/ { in_block=1; print; print "    Interface \"eth0\""; print "    Interface \"end0\""; print "    Interface \"wlan0\""; next }
in_block && /^<\/Plugin>/ { in_block=0; print; next }
in_block && /^[[:space:]]*Interface ".*"/ { next }
{ print }
' "$STAGED_COLLECTD" > "$COLLECTD_TMP"
mv -f "$COLLECTD_TMP" "$STAGED_COLLECTD"

# --- collectd ancillary files ---------------------------------------------

# graphs1090's install.sh does NOT write a collectd unit file. collectd
# ships as an apt-installed package on the feeder, and the runtime overlay
# manifest's systemd.enable list just enables the package's
# /lib/systemd/system/collectd.service.
#
# What install.sh DOES write (via the called malarky.sh):
#   /etc/systemd/system/collectd.service.d/malarky.conf  — tmpfs DataDir override
#   /etc/cron.d/collectd_to_disk                         — nightly persist cron
# Stage both so the on-device install can drop them at the same on-device
# paths and the malarky behaviour (collectd writes to /run/collectd,
# persisted nightly) is preserved.
MALARKY_DROP_IN="$SYSROOT/etc/systemd/system/collectd.service.d/malarky.conf"
if [[ -f "$MALARKY_DROP_IN" ]]; then
    install -d -m 0755 "$OUTPUT_DIR/etc/systemd/system/collectd.service.d"
    cp -a "$MALARKY_DROP_IN" \
        "$OUTPUT_DIR/etc/systemd/system/collectd.service.d/malarky.conf"
fi

MALARKY_CRON="$SYSROOT/etc/cron.d/collectd_to_disk"
if [[ -f "$MALARKY_CRON" ]]; then
    install -d -m 0755 "$OUTPUT_DIR/etc/cron.d"
    cp -a "$MALARKY_CRON" "$OUTPUT_DIR/etc/cron.d/collectd_to_disk"
fi

# --- path-relocatability check --------------------------------------------

# Scan ALL text files in the staged tree (-I = skip binaries) for any
# reference to the scratch / sysroot path. Filter-by-extension would miss
# extensionless files like default-collectd.conf or scripts in subdirs
# (Codex review finding). Also scan symlink targets — `cp -a` preserves
# them — for the same scratch leak.
LEAK_HITS="$( \
    { \
        grep -RIFnH -- "$SYSROOT" "$OUTPUT_DIR" 2>/dev/null || true; \
        grep -RIFnH -- "$SCRATCH_DIR" "$OUTPUT_DIR" 2>/dev/null || true; \
    } || true \
)"
SYMLINK_LEAKS="$( \
    { \
        find "$OUTPUT_DIR" -type l -lname "${SYSROOT}*" -print 2>/dev/null || true; \
        find "$OUTPUT_DIR" -type l -lname "${SCRATCH_DIR}*" -print 2>/dev/null || true; \
    } || true \
)"
if [[ -n "$LEAK_HITS" || -n "$SYMLINK_LEAKS" ]]; then
    {
        echo "stage-graphs1090: scratch/sysroot path leaked into staged tree:"
        [[ -n "$LEAK_HITS"     ]] && echo "$LEAK_HITS"
        [[ -n "$SYMLINK_LEAKS" ]] && echo "symlink targets: $SYMLINK_LEAKS"
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

#!/usr/bin/env bash
# stage-tar1090.sh — run tar1090's install.sh against a scratch sysroot and
# stage the produced files into a release-tree-shaped output dir.
#
# Mirrors `stage-airplanes/03-install-tar1090/01-run-chroot.sh` modulo the
# chroot context: we run install.sh host-side under bubblewrap, with the
# system paths install.sh writes to (/lib/systemd/system, /etc/lighttpd,
# /etc/default, /run, the $ipath tree) bind-mounted from a scratch SYSROOT.
# The relevant files are then copied out of SYSROOT into the staging tree
# the runtime-overlay release tarball will package.
#
# Args:
#   --repo <git-url>
#   --ref <sha-or-branch>
#   --db-repo <git-url>
#   --db-ref <sha-or-branch>
#   --output-dir <staging-dir>
#
# What gets staged (under <output-dir>):
#   share/tar1090/                     HTML tree, tar1090.sh, git-db/, other
#                                      runtime assets install.sh drops at $ipath
#   systemd/tar1090.service            the unit (paths point at the on-device
#                                      install path /usr/local/share/tar1090,
#                                      which is symlinked into the runtime
#                                      overlay on-device)
#   etc/lighttpd/conf-available/88-tar1090.conf
#                                      HTMLPATH already interpolated at
#                                      /usr/local/share/tar1090/html
#   components.tar1090.sha             upstream tar1090 SHA
#   components.tar1090_db.sha          upstream tar1090-db SHA
#
# Why $ipath is the on-device path (not a SYSROOT-relative one):
#   tar1090's installer hardcodes /usr/local/share/tar1090 references in
#   the service unit (EnvironmentFile=, ExecStart=) and produces a lighttpd
#   snippet whose HTMLPATH token is replaced with $ipath. Passing $ipath as
#   /usr/local/share/tar1090 means the produced unit + lighttpd snippet
#   already carry the on-device absolute paths. The runtime-overlay
#   install.sh symlinks /usr/local/share/tar1090 → /opt/airplanes-runtime/
#   current/share/tar1090 on-device, so those absolute paths resolve
#   correctly without a per-release rewrite.
#
# Dependency: bubblewrap (`bwrap`) must be on PATH. On Debian/Ubuntu:
#   apt-get install bubblewrap

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

usage() {
    cat >&2 <<'USAGE'
usage: stage-tar1090.sh \
    --repo <git-url> \
    --ref <sha-or-branch> \
    --db-repo <git-url> \
    --db-ref <sha-or-branch> \
    --output-dir <staging-dir>
USAGE
}

die() {
    echo "stage-tar1090: $*" >&2
    exit 1
}

REPO=""
REF=""
DB_REPO=""
DB_REF=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        REPO="${2-}";        shift 2 ;;
        --ref)         REF="${2-}";         shift 2 ;;
        --db-repo)     DB_REPO="${2-}";     shift 2 ;;
        --db-ref)      DB_REF="${2-}";      shift 2 ;;
        --output-dir)  OUTPUT_DIR="${2-}";  shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; echo "stage-tar1090: unknown argument: $1" >&2; exit 2 ;;
    esac
done

for required in REPO REF DB_REPO DB_REF OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        echo "stage-tar1090: missing required --$flag" >&2
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

SCRATCH_DIR="$(mktemp -d -t stage-tar1090.XXXXXX)"
# shellcheck disable=SC2064
trap 'rm -rf -- "$SCRATCH_DIR"' EXIT

# tar1090 source goes here.
BUILD_DIR="$SCRATCH_DIR/tar1090-src"
fetch_repo "$BUILD_DIR" "$REPO" "$REF"
TAR1090_SHA="$(git -C "$BUILD_DIR" rev-parse HEAD)"

# tar1090-db is pre-populated under $gpath/git-db where $gpath = $ipath
# (default). install.sh would otherwise auto-refresh from upstream master;
# repointing the local clone's origin at a guaranteed-to-fail URL keeps our
# pinned ref in place — same trick stage 03 uses.
SYSROOT="$SCRATCH_DIR/sysroot"
IPATH_REL="usr/local/share/tar1090"
IPATH_ABS="/$IPATH_REL"
install -d -m 0755 \
    "$SYSROOT$IPATH_ABS" \
    "$SYSROOT/etc/lighttpd/conf-available" \
    "$SYSROOT/etc/lighttpd/conf-enabled" \
    "$SYSROOT/etc/default" \
    "$SYSROOT/lib/systemd/system" \
    "$SYSROOT/run/readsb"

TAR1090_DB_DIR="$SYSROOT$IPATH_ABS/git-db"
fetch_repo "$TAR1090_DB_DIR" "$DB_REPO" "$DB_REF"
TAR1090_DB_SHA="$(git -C "$TAR1090_DB_DIR" rev-parse HEAD)"
git -C "$TAR1090_DB_DIR" remote set-url origin file:///dev/null/airplanes-pinned

# install.sh sed-edits /etc/lighttpd/lighttpd.conf if it considers lighttpd
# enabled. Provide an empty stub — `sed -i 's/pattern/repl/'` is a no-op on
# files with no matching lines. The conf-enabled/ symlink-target install.sh
# emits is what we actually care about; the host's lighttpd.conf is not.
: > "$SYSROOT/etc/lighttpd/lighttpd.conf"

# install.sh also creates a tar1090 system user when systemctl is detected.
# We stub systemctl out below so useSystemd=no and the adduser step is
# skipped entirely. Either path is safe for a build-time stage: on-device
# install creates the user via post_install hooks declared in the runtime
# overlay manifest.

# Stub out commands install.sh might call that we don't want hitting the
# host: systemctl (daemon-reload), pkill (the script also has its own;
# defensive), service. Stage 04 has the same pkill pitfall.
SHIM_BIN="$SCRATCH_DIR/shim-bin"
install -d -m 0755 "$SHIM_BIN"
for cmd in systemctl pkill service; do
    {
        printf '#!/bin/sh\n'
        printf 'echo "%s stub (stage-tar1090): $*" >&2\n' "$cmd"
        printf 'exit 0\n'
    } > "$SHIM_BIN/$cmd"
    chmod 0755 "$SHIM_BIN/$cmd"
done

# Run install.sh under bwrap. Bind:
#   $SYSROOT$IPATH_ABS                → $IPATH_ABS
#   $SYSROOT/lib/systemd/system       → /lib/systemd/system
#   $SYSROOT/etc/lighttpd/...         → /etc/lighttpd/...
#   $SYSROOT/etc/default              → /etc/default
#   $SYSROOT/run/readsb               → /run/readsb
#   $SHIM_BIN ahead of host PATH      → stub systemctl/pkill/service
# Read-only everywhere else. /proc and /dev/null are useful for the install
# script's misc calls.
PATH_IN="$SHIM_BIN:/usr/bin:/bin"

# --unshare-pid: defense in depth — tar1090 install.sh is not known to
# daemonize anything, but isolating the sandbox PID namespace means any
# unexpected leak dies with bwrap exit instead of surviving on the host.
bwrap \
    --unshare-pid \
    --ro-bind / / \
    --dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --bind "$SYSROOT$IPATH_ABS"                "$IPATH_ABS" \
    --bind "$SYSROOT/lib/systemd/system"       /lib/systemd/system \
    --bind "$SYSROOT/etc/lighttpd"             /etc/lighttpd \
    --bind "$SYSROOT/etc/default"              /etc/default \
    --bind "$SYSROOT/run/readsb"               /run/readsb \
    --bind "$BUILD_DIR"                        "$BUILD_DIR" \
    --setenv PATH "$PATH_IN" \
    --chdir "$BUILD_DIR" \
    -- bash "$BUILD_DIR/install.sh" \
        /run/readsb \
        tar1090 \
        "$IPATH_ABS" \
        "$BUILD_DIR" \
    || die "tar1090 install.sh failed under bwrap"

# --- collect staging tree --------------------------------------------------

install -d -m 0755 \
    "$OUTPUT_DIR/share/tar1090" \
    "$OUTPUT_DIR/systemd" \
    "$OUTPUT_DIR/etc/lighttpd/conf-available"

# Drop install.sh's working git/ — it's a cache for future upgrades, not a
# runtime asset. Keep git-db/ — runtime aircraft DB lookups read from there.
rm -rf -- "$SYSROOT$IPATH_ABS/git" || true

cp -a "$SYSROOT$IPATH_ABS/." "$OUTPUT_DIR/share/tar1090/"

# Capture the systemd unit.
TAR1090_UNIT="$SYSROOT/lib/systemd/system/tar1090.service"
[[ -f "$TAR1090_UNIT" ]] || die "tar1090 install did not produce $TAR1090_UNIT"
cp -a "$TAR1090_UNIT" "$OUTPUT_DIR/systemd/tar1090.service"

# Capture lighttpd snippet. install.sh produces 88-tar1090.conf for the
# non-webroot default-instance case (the one stage 03 mirrors). It also
# produces 95-tar1090-otherport.conf (the alt-port :8504 listener), which
# stage 03 explicitly drops via the conf-enabled symlink. We don't ship
# the otherport listener at all in the release.
LIGHTTPD_SRC="$SYSROOT/etc/lighttpd/conf-available"
[[ -f "$LIGHTTPD_SRC/88-tar1090.conf" ]] \
    || die "tar1090 install did not produce $LIGHTTPD_SRC/88-tar1090.conf"
cp -a "$LIGHTTPD_SRC/88-tar1090.conf" \
    "$OUTPUT_DIR/etc/lighttpd/conf-available/88-tar1090.conf"

# --- path-relocatability post-check ---------------------------------------

# Any reference to the SCRATCH or SYSROOT path in shell/unit/conf files
# inside the staged tree would survive the tarball and fail at runtime.
# Grep for both prefixes; a single match fails the build. The check is
# scoped to text-format files install.sh produces.
LEAK_HITS="$( \
    { \
        grep -RFnH -- "$SYSROOT" \
            "$OUTPUT_DIR/share/tar1090" \
            "$OUTPUT_DIR/systemd" \
            "$OUTPUT_DIR/etc/lighttpd" \
            2>/dev/null || true; \
        grep -RFnH -- "$SCRATCH_DIR" \
            "$OUTPUT_DIR/share/tar1090" \
            "$OUTPUT_DIR/systemd" \
            "$OUTPUT_DIR/etc/lighttpd" \
            2>/dev/null || true; \
    } | grep -E '\.(sh|service|conf)(:|$)' || true \
)"
if [[ -n "$LEAK_HITS" ]]; then
    {
        echo "stage-tar1090: scratch/sysroot path leaked into staged tree:"
        echo "$LEAK_HITS"
    } >&2
    exit 1
fi

# --- lighttpd syntax check ------------------------------------------------

# The conf-available snippet alone does not parse — it depends on the main
# lighttpd.conf loading mod_alias / mod_setenv. Wrap it in a minimal
# harness so a syntax error in the produced snippet surfaces here.
if command -v lighttpd >/dev/null 2>&1; then
    HARNESS="$SCRATCH_DIR/lighttpd-harness.conf"
    {
        echo 'server.document-root = "/tmp"'
        echo 'server.modules = ( "mod_alias", "mod_setenv" )'
        printf 'include "%s"\n' \
            "$OUTPUT_DIR/etc/lighttpd/conf-available/88-tar1090.conf"
    } > "$HARNESS"
    if ! lighttpd -tt -f "$HARNESS" >/dev/null 2>&1; then
        {
            echo "stage-tar1090: lighttpd -tt rejected 88-tar1090.conf:"
            lighttpd -tt -f "$HARNESS" || true
        } >&2
        exit 1
    fi
fi

# --- pin records ----------------------------------------------------------

printf '%s\n' "$TAR1090_SHA"    > "$OUTPUT_DIR/components.tar1090.sha"
printf '%s\n' "$TAR1090_DB_SHA" > "$OUTPUT_DIR/components.tar1090_db.sha"

echo "stage-tar1090: staged tar1090 $TAR1090_SHA + tar1090-db $TAR1090_DB_SHA"

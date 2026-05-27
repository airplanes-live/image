#!/usr/bin/env bash
# lighttpd-verify.sh — run `lighttpd -tt -f <conf>` against every
# conf-available snippet shipped in a runtime-overlay release tree.
#
# `lighttpd -tt` performs a full config parse (including module load) without
# touching network sockets, so it is safe to run on a CI runner. We point
# lighttpd at a thin top-level config that does an `include_shell` over the
# release's conf-available/ snippet, with var.log_root / var.state_dir / etc.
# set to scratch dirs so a snippet that references them does not fail on
# missing host paths.
#
# Args:
#   --release-dir <path>   the v<X> release tree to verify
#
# Exits 0 iff every snippet parses cleanly.

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: lighttpd-verify.sh --release-dir <path-to-release-tree>
USAGE
}

die() {
    echo "lighttpd-verify: $*" >&2
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

confs_dir="$RELEASE_DIR/etc/lighttpd/conf-available"
if [[ ! -d "$confs_dir" ]]; then
    echo "lighttpd-verify: no $confs_dir — nothing to verify (ok)"
    exit 0
fi

shopt -s nullglob
confs=("$confs_dir"/*.conf)
shopt -u nullglob

if [[ "${#confs[@]}" -eq 0 ]]; then
    echo "lighttpd-verify: no .conf files under $confs_dir — nothing to verify (ok)"
    exit 0
fi

if ! command -v lighttpd >/dev/null 2>&1; then
    die "lighttpd not on PATH (apt install lighttpd)"
fi

scratch="$(mktemp -d -t lighttpd-verify.XXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT

install -d -m 0755 \
    "$scratch/var/log/lighttpd" \
    "$scratch/var/run/lighttpd" \
    "$scratch/var/cache/lighttpd" \
    "$scratch/var/www/html" \
    "$scratch/etc/lighttpd"

# Verify each snippet in isolation. The top-level config sets the minimum
# directives lighttpd insists on (server.document-root, error log) AND
# pre-loads the standard module set that runtime-overlay snippets depend on
# — `alias.url` needs mod_alias, `setenv.add-response-header` needs
# mod_setenv, `dir-listing.activate` needs mod_dirlisting. Snippet authors
# who add new directives requiring an unlisted module hit a clean failure
# here. The module list mirrors what stage-tar1090.sh / stage-graphs1090.sh
# already load when they syntax-check the snippets they produce.
fail=0
for conf in "${confs[@]}"; do
    name="$(basename -- "$conf")"
    wrapper="$scratch/etc/lighttpd/wrap-$name"
    cat > "$wrapper" <<WRAP
server.document-root = "$scratch/var/www/html"
server.errorlog      = "$scratch/var/log/lighttpd/error.log"
server.pid-file      = "$scratch/var/run/lighttpd/lighttpd.pid"
server.port          = 8080
server.modules       = ( "mod_alias", "mod_setenv", "mod_dirlisting", "mod_proxy" )
include "$conf"
WRAP
    if ! lighttpd -tt -f "$wrapper" >"$scratch/$name.out" 2>&1; then
        echo "lighttpd-verify: $name FAILED" >&2
        sed 's/^/  /' "$scratch/$name.out" >&2 || true
        fail=1
    else
        echo "lighttpd-verify: $name ok"
    fi
done

exit "$fail"

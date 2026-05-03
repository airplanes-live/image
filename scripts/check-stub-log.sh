#!/bin/bash
# Verify that the systemctl-stub was actually exercised during stages 01-05
# and that no start/restart line ever made it through. Writes a one-line
# fingerprint into the rootfs that later steps (manifest, release smoke) can
# fold into the build provenance.
#
# Usage: check-stub-log.sh ROOTFS_DIR

set -euo pipefail

ROOTFS_DIR="${1:?ROOTFS_DIR required}"
LOG="${ROOTFS_DIR}/var/log/airplanes-systemctl-stub.log"
FINGERPRINT="${ROOTFS_DIR}/etc/airplanes/.build-stub-fingerprint"

if [[ ! -s "$LOG" ]]; then
	echo "ERROR: ${LOG} missing or empty — install.sh did not exercise the systemctl shim" >&2
	exit 1
fi

# Match verbs only at whitespace-bounded token positions. \b would also match
# inside hyphenated unit names (e.g. "enable foo-stop.service" gives a false
# positive on "stop" because - is a word boundary).
FORBIDDEN_RE='[[:space:]](start|restart|stop|kill)([[:space:]]|$)'
if grep -E -q "$FORBIDDEN_RE" "$LOG"; then
	echo "ERROR: ${LOG} contains forbidden lifecycle verbs — host services were touched during build" >&2
	grep -E "$FORBIDDEN_RE" "$LOG" >&2
	exit 1
fi

invocations="$(wc -l < "$LOG" | tr -d ' ')"
enables="$(grep -c -E '[[:space:]]enable([[:space:]]|$)' "$LOG" || true)"

install -d -m 755 "$(dirname "$FINGERPRINT")"
printf 'invocations=%s enables=%s ts=%s\n' \
	"$invocations" "$enables" "$(date -u +%FT%TZ)" \
	> "$FINGERPRINT"

echo "stub fingerprint: invocations=${invocations} enables=${enables}"

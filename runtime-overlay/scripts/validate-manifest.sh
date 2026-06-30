#!/usr/bin/env bash
# Validates a runtime-overlay release manifest.json against the schema
# shipped alongside this script and runs cross-field checks that JSON Schema
# can't express portably (currently: migration-id uniqueness).
#
# Usage:  validate-manifest.sh <path-to-manifest.json>
# Exits 0 if valid; non-zero with a single-line diagnostic on failure.
#
# Dependencies:
#   - jq                              (Debian: jq)
#   - python3 + jsonschema            (Debian: python3-jsonschema)
#
# Optional: the rfc3339-validator PyPI package enables strict enforcement of
# `format: date-time` on `build_date`. Without it, jsonschema falls through to
# a permissive default. The regex pattern on `version` and the structural
# checks below remain enforced either way.
#
# The script intentionally avoids dependency on a network-fetched meta-schema:
# Draft 2020-12 vocabularies are built into jsonschema >= 4.0.0.
#
# The script reads the manifest into memory exactly once and runs every gate
# against that snapshot, so a concurrent rewrite of the manifest file mid-run
# cannot produce a false positive.

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
schema_path="${_self_dir}/../schema/manifest.schema.json"

usage() {
    echo "usage: $(basename "$0") <manifest.json>" >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

manifest_path="$1"

if [[ ! -f "$manifest_path" ]]; then
    echo "validate-manifest: manifest not found: $manifest_path" >&2
    exit 2
fi

if [[ ! -f "$schema_path" ]]; then
    echo "validate-manifest: schema not found: $schema_path" >&2
    exit 2
fi

# Snapshot the manifest into a temp file under the user's runtime dir so all
# subsequent checks operate on the same bytes. mktemp + trap ensures cleanup
# on every exit path including signals.
snapshot="$(mktemp)"
trap 'rm -f "$snapshot"' EXIT
cp -- "$manifest_path" "$snapshot"

# 1. JSON-parseability gate. We need to distinguish "missing jq" (exit 2 from
#    bash's `command -v` flow if it ran) from "jq returned non-zero", but in
#    practice jq is a hard dependency declared in the header — a missing-jq
#    runtime is a packaging bug, not user input. Be explicit anyway.
if ! command -v jq >/dev/null 2>&1; then
    echo "validate-manifest: required dependency 'jq' not found on PATH" >&2
    exit 2
fi

if ! jq -e . "$snapshot" >/dev/null 2>&1; then
    echo "validate-manifest: manifest is not valid JSON: $manifest_path" >&2
    exit 1
fi

# 2. Schema validation. Run as a child Python process so syntax errors in the
#    inline script surface as a script error, not a bash quoting trap.
if ! python3 - "$schema_path" "$snapshot" <<'PY'
import json
import sys

from jsonschema import Draft202012Validator

schema_path, doc_path = sys.argv[1], sys.argv[2]

with open(schema_path, "rb") as fh:
    schema = json.load(fh)
with open(doc_path, "rb") as fh:
    doc = json.load(fh)

validator = Draft202012Validator(
    schema,
    format_checker=Draft202012Validator.FORMAT_CHECKER,
)

errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path))
if errors:
    for err in errors:
        path = "/".join(str(p) for p in err.absolute_path) or "<root>"
        # err.message is already a single line in practice; defensive replace
        # keeps grep-friendly output if a custom schema ever embeds newlines.
        msg = err.message.replace("\n", " ")
        print(f"validate-manifest: schema error at {path}: {msg}", file=sys.stderr)
    sys.exit(1)
PY
then
    exit 1
fi

# 3. Cross-field gate: migration ids must be unique within a release.
#    JSON Schema's uniqueItems compares whole objects, not a projection;
#    enforcing this in jq is more portable than a custom validator keyword.
dup_ids="$(jq -r '
    [.migrations[].id]
    | group_by(.)
    | map(select(length > 1) | .[0])
    | join(",")
' "$snapshot")"

if [[ -n "$dup_ids" ]]; then
    echo "validate-manifest: duplicate migration ids: ${dup_ids}" >&2
    exit 1
fi

# 4. Cross-field gate: managed destinations (symlink link, copy path, mutable
#    path) must not duplicate or parent/child-overlap each other. An overlap
#    means a rollback that restores one destination could clobber a file
#    restored for another (e.g. a copy target under a symlink-managed dir).
overlap_report="$(jq -r '
    ([ (.managed_paths // [])[]
       | if .mode == "symlink" then .link
         elif .mode == "copy"  then .path
         else empty end ]
     + (.mutable_paths // [])) as $dests
    | ($dests | group_by(.) | map(select(length > 1) | .[0])) as $dups
    | [ $dests[] | {p:., c:(split("/") | map(select(length > 0)))} ] as $items
    | [ $items[] as $a | $items[] as $b
        | select(($a.c | length) < ($b.c | length)
                 and $b.c[0:($a.c | length)] == $a.c)
        | "\($a.p) contains \($b.p)" ] as $overlaps
    | ($dups | map("duplicate: \(.)")) + $overlaps
    | join("; ")
' "$snapshot")"

if [[ -n "$overlap_report" ]]; then
    echo "validate-manifest: overlapping managed destinations: ${overlap_report}" >&2
    exit 1
fi

# 5. Cross-field gate: managed destinations must not squat a filesystem tree we
#    don't own. The device payload lives under /opt/airplanes; a managed symlink
#    or copy landing in /usr/bin, /usr/local/lib/airplanes*, /usr/local/share/airplanes*,
#    or /usr/share/airplanes* means the overlay is writing into OS- or
#    distribution-owned trees. /usr/local/bin launchers and the kept third-party
#    read-only data dirs (/usr/local/share/tar1090, /usr/share/graphs1090) are fine.
squat_report="$(jq -r '
    [ (.managed_paths // [])[]
      | (if .mode == "symlink" then .link elif .mode == "copy" then .path else empty end) as $d
      | select($d != null)
      | select(
          ($d | startswith("/usr/bin/")) or
          ($d | startswith("/usr/local/lib/airplanes")) or
          ($d | startswith("/usr/local/share/airplanes")) or
          ($d | startswith("/usr/share/airplanes"))
        )
      | $d ]
    | join("; ")
' "$snapshot")"

if [[ -n "$squat_report" ]]; then
    echo "validate-manifest: managed destination squats a tree we do not own (FHS): ${squat_report}" >&2
    exit 1
fi

exit 0

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

# 1. JSON-parseability gate — catches malformed JSON early with a clearer
#    message than jsonschema's stacktrace.
if ! jq -e . "$manifest_path" >/dev/null 2>&1; then
    echo "validate-manifest: manifest is not valid JSON: $manifest_path" >&2
    exit 1
fi

# 2. Schema validation. Run as a child Python process so syntax errors in the
#    inline script surface as a script error, not a bash quoting trap.
if ! python3 - "$schema_path" "$manifest_path" <<'PY'
import json
import sys

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

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
dup_count="$(jq -r '
    [.migrations[].id]
    | (length) as $n
    | unique
    | length as $u
    | $n - $u
' "$manifest_path")"

if [[ "$dup_count" -gt 0 ]]; then
    dup_ids="$(jq -r '
        [.migrations[].id]
        | group_by(.)
        | map(select(length > 1) | .[0])
        | join(",")
    ' "$manifest_path")"
    echo "validate-manifest: duplicate migration ids: ${dup_ids}" >&2
    exit 1
fi

exit 0

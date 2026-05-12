#!/usr/bin/env bash
# Parity test between the JS validators in webconfig/web/assets/app.js
# (client-side preview / Save-button gating) and the bash validators in
# feed/scripts/lib/configure-validators.sh (server-side reject via
# apl-feed apply). A drift between them shows up as "form looks valid
# but save failed" — UX-bad, easy to overlook in unit tests on either
# side alone.
#
# How it works:
#   1. Extract the JS block between the /* @validator-parity ... */ markers
#      in app.js into a temp .js file. Append a CommonJS dispatch shim so
#      Node can call any validator by name.
#   2. Read fixtures from test/fixtures/validator-parity.json — each row is
#      (validator, value, expected_bool).
#   3. For each row, run Node against the extracted JS validators AND bash
#      against feed's configure-validators.sh. Both results must equal the
#      expected value; if not, fail with the divergence.
#
# Feed source: cloned into $AIRPLANES_FEED_ROOT in CI (mirrors the
# feed-overlay-smoke job). Local-dev fallback: sibling repo checkout one
# directory up from the image repo.
#
# Exit codes:
#   0    all rows agree
#   1    at least one row diverges (or expected mismatch)
#   2    setup error (missing node / feed checkout / jq / app.js block)

set -euo pipefail

IMAGE_ROOT="${IMAGE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
FEED_ROOT="${AIRPLANES_FEED_ROOT:-}"
if [[ -z "$FEED_ROOT" ]]; then
    # Local-dev fallback: sibling checkout one level up.
    if [[ -d "$IMAGE_ROOT/../feed" ]]; then
        FEED_ROOT="$(cd "$IMAGE_ROOT/../feed" && pwd)"
    fi
fi

die() { echo "ERROR: $*" >&2; exit 2; }

[[ -n "$FEED_ROOT" ]] \
    || die "feed checkout not found. Set AIRPLANES_FEED_ROOT, or clone airplanes-live/feed beside image/."
[[ -f "$FEED_ROOT/scripts/lib/configure-validators.sh" ]] \
    || die "$FEED_ROOT/scripts/lib/configure-validators.sh not found."

APP_JS="$IMAGE_ROOT/webconfig/web/assets/app.js"
FIXTURE="$IMAGE_ROOT/test/fixtures/validator-parity.json"
[[ -f "$APP_JS" ]]   || die "$APP_JS not found."
[[ -f "$FIXTURE" ]]  || die "$FIXTURE not found."

command -v node >/dev/null 2>&1 || die "node is required."
command -v jq >/dev/null 2>&1   || die "jq is required."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract the JS validator block between markers. awk in single-quotes
# keeps the literal `*/` from terminating the shell.
JS_BLOCK="$WORK/validators.js"
awk '
    /\/\* @validator-parity start \*\// { inside = 1; next }
    /\/\* @validator-parity end \*\// { inside = 0; next }
    inside { print }
' "$APP_JS" > "$JS_BLOCK"

if [[ ! -s "$JS_BLOCK" ]]; then
    die "validator block not found in $APP_JS — check the /* @validator-parity */ markers."
fi

# Append a CommonJS dispatch shim — Node invokes it with (validator, value)
# on argv and prints "true"/"false" on stdout.
cat >> "$JS_BLOCK" <<'JS_DISPATCH'

const dispatch = {
    latitude: isValidLatitude,
    longitude: isValidLongitude,
    altitude: isValidAltitude,
};
const [,, name, value] = process.argv;
const fn = dispatch[name];
if (!fn) {
    process.stderr.write(`unknown validator: ${name}\n`);
    process.exit(2);
}
process.stdout.write(fn(value) ? "true" : "false");
JS_DISPATCH

# Bash dispatcher — sources configure-validators.sh once and dispatches on
# the validator name. Run as a child process per row so a `set -e` abort
# in one row doesn't take down the test driver.
BASH_DRIVER="$WORK/bash_validator.sh"
cat > "$BASH_DRIVER" <<BASH_DRIVER_EOF
#!/usr/bin/env bash
set -u
# shellcheck source=/dev/null
source "$FEED_ROOT/scripts/lib/configure-validators.sh"
case "\$1" in
    latitude)  fn=valid_latitude  ;;
    longitude) fn=valid_longitude ;;
    altitude)  fn=valid_altitude  ;;
    *) echo "unknown" >&2; exit 2 ;;
esac
if "\$fn" "\$2"; then echo true; else echo false; fi
BASH_DRIVER_EOF
chmod +x "$BASH_DRIVER"

passed=0
failed=0
failures=()

total="$(jq '.tests | length' "$FIXTURE")"

i=0
while (( i < total )); do
    row="$(jq -c ".tests[$i]" "$FIXTURE")"
    validator="$(jq -r '.validator' <<<"$row")"
    value="$(jq -r '.value' <<<"$row")"
    expected="$(jq -r '.expected' <<<"$row")"

    js_result="$(node "$JS_BLOCK" "$validator" "$value")"
    bash_result="$("$BASH_DRIVER" "$validator" "$value")"

    if [[ "$js_result" == "$expected" && "$bash_result" == "$expected" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        failures+=("$validator($value): expected=$expected js=$js_result bash=$bash_result")
    fi
    i=$((i + 1))
done

if (( failed > 0 )); then
    echo "FAIL: $failed / $total row(s) diverged or mismatched expected." >&2
    for f in "${failures[@]}"; do
        echo "  - $f" >&2
    done
    exit 1
fi

echo "validator parity: $passed / $total rows passed (JS + bash both match expected)"

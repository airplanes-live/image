#!/usr/bin/env bats

# build-image.yml (real, on.pull_request.paths) and build-image-skipped.yml
# (stub, on.pull_request.paths-ignore) implement the required-check mirror
# for path-filtered workflows: exactly one of them must fire on any PR.
# Drift between the two lists means some PRs get either NO check runs for
# the ruleset-required contexts (merge blocked forever) or duplicate ones.
# Same for the job names: the stub only satisfies the ruleset if its
# check-run names match what the real workflow produces on a PR run.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    REAL="$REPO_ROOT/.github/workflows/build-image.yml"
    STUB="$REPO_ROOT/.github/workflows/build-image-skipped.yml"
}

# extract_list <file> <key> — prints the pattern lines of the flow-style
# YAML list under `    <key>:` (4-space indent, entries at 6 spaces), as
# written in both workflow files. Stops at the first non-entry line.
extract_list() {
    awk -v key="$2" '
        $0 == "    " key ":" { grab = 1; next }
        grab && /^      - / { sub(/^ +- /, ""); print; next }
        grab && /^ *#/ { next }
        grab { exit }
    ' "$1"
}

@test "stub paths-ignore mirrors build-image pull_request paths exactly" {
    real_list="$(extract_list "$REAL" "paths")"
    stub_list="$(extract_list "$STUB" "paths-ignore")"
    [ -n "$real_list" ]
    [ -n "$stub_list" ]
    diff <(printf '%s\n' "$real_list") <(printf '%s\n' "$stub_list")
}

@test "stub job names pair with the real workflow's PR-run check names" {
    # Static names must exist verbatim in both files.
    for n in \
        "Resolve product release identity" \
        "Verify runtime-overlay gates" \
        "Sign runtime-overlay assets"; do
        grep -qF "name: $n" "$REAL"
        grep -qF "name: $n" "$STUB"
    done
    # Dynamic names: PR runs of the real workflow always resolve
    # channel=dev and build arm64 only, so the stub hardcodes the
    # dev/arm64 expansion of each templated name.
    grep -qF 'name: build-${{ needs.resolve-product.outputs.channel }}-${{ matrix.arch }}' "$REAL"
    grep -qF 'name: build-dev-arm64' "$STUB"
    grep -qF 'name: boot-smoke-${{ needs.resolve-product.outputs.channel }}-${{ matrix.arch }}' "$REAL"
    grep -qF 'name: boot-smoke-dev-arm64' "$STUB"
    grep -qF 'name: runtime-overlay-upgrade-${{ needs.resolve-product.outputs.channel }}-${{ matrix.arch }}' "$REAL"
    grep -qF 'name: runtime-overlay-upgrade-dev-arm64' "$STUB"
}

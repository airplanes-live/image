#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/validate-manifest.sh. Exercises the
# schema validator against the golden example plus targeted negatives that
# pin the schema's most load-bearing constraints (oneOf branches, enums,
# uniqueness gate).
#
# Each test mutates a copy of the golden example via jq under
# $BATS_TEST_TMPDIR, then invokes the validator with the mutated path. Tests
# assert exit status and a fragment of the diagnostic so a future schema
# rewrite that silently relaxes a rule fails here.

bats_require_minimum_version 1.5.0

setup() {
    VALIDATOR="$BATS_TEST_DIRNAME/../../runtime-overlay/scripts/validate-manifest.sh"
    GOLDEN="$BATS_TEST_DIRNAME/../../runtime-overlay/schema/example-manifest.json"
    [ -x "$VALIDATOR" ] || skip "validator not executable: $VALIDATOR"
    [ -f "$GOLDEN" ]    || skip "golden manifest missing: $GOLDEN"
}

# Helper: copy the golden example into BATS_TEST_TMPDIR and apply a jq
# expression to it, leaving the mutated file at $BATS_TEST_TMPDIR/manifest.json.
mutate_golden() {
    local jq_expr="$1"
    local out="$BATS_TEST_TMPDIR/manifest.json"
    jq "$jq_expr" "$GOLDEN" > "$out"
    echo "$out"
}

@test "validates the golden example" {
    run "$VALIDATOR" "$GOLDEN"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rejects invalid JSON" {
    local bad="$BATS_TEST_TMPDIR/bad.json"
    printf '%s' '{ not: valid json' > "$bad"
    run "$VALIDATOR" "$bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid JSON"* ]]
}

@test "rejects manifest missing a required top-level key" {
    local mutated
    mutated="$(mutate_golden 'del(.version)')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
    [[ "$output" == *"version"* ]]
    [[ "$output" == *"required"* ]]
}

@test "rejects channel outside the enum" {
    local mutated
    mutated="$(mutate_golden '.channel = "stage"')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
    [[ "$output" == *"channel"* ]]
}

@test "rejects version that doesn't match the semver pattern" {
    local mutated
    mutated="$(mutate_golden '.version = "1.4"')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
    [[ "$output" == *"version"* ]]
}

@test "rejects managed_paths symlink entry that carries a copy-only field" {
    # Find the first symlink-mode entry and bolt 'owner' onto it. Schema's
    # oneOf branch with additionalProperties:false should fail it.
    local mutated
    mutated="$(mutate_golden '
        (.managed_paths
         | map(if .mode == "symlink"
               then . + {owner: "root:root"}
               else .
               end)) as $p
        | .managed_paths = $p
    ')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
}

@test "rejects shell migration missing rollback_script" {
    local mutated
    mutated="$(mutate_golden '
        (.migrations
         | map(if .type == "shell"
               then del(.rollback_script)
               else .
               end)) as $m
        | .migrations = $m
    ')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
}

@test "rejects duplicate migration ids" {
    # Duplicate an existing migration entry — schema may not catch it, but
    # the post-schema dedup gate in the validator must.
    local mutated
    mutated="$(mutate_golden '.migrations += [.migrations[0]]')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate migration ids"* ]]
}

@test "rejects channel=stable paired with a dev-shaped version" {
    local mutated
    mutated="$(mutate_golden '.channel = "stable" | .version = "1.4.0-dev-20260519-abcdef0"')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
}

@test "rejects channel=dev paired with a stable-shaped version" {
    local mutated
    mutated="$(mutate_golden '.channel = "dev" | .version = "1.4.0"')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
}

@test "accepts a well-formed dev-channel manifest" {
    local mutated
    mutated="$(mutate_golden '.channel = "dev" | .version = "1.4.0-dev-20260519-abcdef0"')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -eq 0 ]
}

@test "rejects relPath containing a .. segment" {
    # The schema's relPath def forbids '..' in any segment, so a shell
    # migration whose script tries to escape the release dir must fail.
    local mutated
    mutated="$(mutate_golden '
        (.migrations
         | map(if .type == "shell"
               then .script = "../etc/passwd"
               else .
               end)) as $m
        | .migrations = $m
    ')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
}

@test "rejects duplicate managed destinations (copy path equals a symlink link)" {
    # Point the copy-mode path at an existing symlink link → duplicate dest.
    local mutated
    mutated="$(mutate_golden '
        (.managed_paths
         | map(if .mode == "copy"
               then .path = "/usr/bin/readsb"
               else .
               end)) as $p
        | .managed_paths = $p
    ')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
    [[ "$output" == *"overlapping managed destinations"* ]]
    [[ "$output" == *"duplicate"* ]]
}

@test "rejects parent/child-overlapping managed destinations" {
    # Add a mutable path nested under a symlink-managed directory.
    local mutated
    mutated="$(mutate_golden '.mutable_paths += ["/usr/local/share/tar1090/config"]')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -ne 0 ]
    [[ "$output" == *"overlapping managed destinations"* ]]
    [[ "$output" == *"contains"* ]]
}

@test "accepts disjoint destinations that share only a string prefix" {
    # A sibling sharing a string prefix but NOT a path-component ancestor passes.
    local mutated
    mutated="$(mutate_golden '.mutable_paths += ["/usr/local/share/tar1090-extra"]')"
    run "$VALIDATOR" "$mutated"
    [ "$status" -eq 0 ]
}

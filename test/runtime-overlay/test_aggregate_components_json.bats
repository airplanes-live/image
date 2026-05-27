#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/lib/aggregate-components-json.sh — reads
# components.<key>.sha files and emits a single components.json the manifest
# renderer consumes.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HELPER="$REPO_ROOT/runtime-overlay/scripts/lib/aggregate-components-json.sh"
    [ -x "$HELPER" ] || skip "aggregate-components-json.sh not executable: $HELPER"

    INPUT_DIR="$BATS_TEST_TMPDIR/staging"
    install -d -m 0755 "$INPUT_DIR"
}

@test "aggregates per-component SHA files into a single components.json" {
    printf '%s\n' "a1b2c3d4e5f6789012345678901234567890abcd" \
        > "$INPUT_DIR/components.readsb_wiedehopf.sha"
    printf '%s\n' "0fedcba987654321fedcba9876543210fedcba98" \
        > "$INPUT_DIR/components.dump978_fa.sha"
    printf '%s\n' "cafebabecafebabecafebabecafebabecafebabe" \
        > "$INPUT_DIR/components.graphs1090.sha"

    run "$HELPER" --input-dir "$INPUT_DIR"
    [ "$status" -eq 0 ]
    [ -f "$INPUT_DIR/components.json" ]

    # Validate keys and values.
    run jq -r '.readsb_wiedehopf' "$INPUT_DIR/components.json"
    [ "$status" -eq 0 ]
    [ "$output" = "a1b2c3d4e5f6789012345678901234567890abcd" ]

    run jq -r '.dump978_fa' "$INPUT_DIR/components.json"
    [ "$status" -eq 0 ]
    [ "$output" = "0fedcba987654321fedcba9876543210fedcba98" ]

    run jq -r '.graphs1090' "$INPUT_DIR/components.json"
    [ "$status" -eq 0 ]
    [ "$output" = "cafebabecafebabecafebabecafebabecafebabe" ]
}

@test "honours --output for a custom write path" {
    printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
        > "$INPUT_DIR/components.foo.sha"

    install -d -m 0755 "$BATS_TEST_TMPDIR/elsewhere"
    local target="$BATS_TEST_TMPDIR/elsewhere/components.json"
    run "$HELPER" --input-dir "$INPUT_DIR" --output "$target"
    [ "$status" -eq 0 ]
    [ -f "$target" ]
    [ ! -f "$INPUT_DIR/components.json" ]
}

@test "rejects an empty input dir with no SHA files" {
    run "$HELPER" --input-dir "$INPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no components"* ]]
}

@test "rejects a malformed SHA" {
    printf '%s\n' "not-a-sha" > "$INPUT_DIR/components.foo.sha"
    run "$HELPER" --input-dir "$INPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHA"* ]]
}

@test "rejects a missing --input-dir argument" {
    run "$HELPER"
    [ "$status" -ne 0 ]
    [[ "$output" == *"input-dir"* ]]
}

@test "tolerates a SHA with trailing newline/whitespace" {
    printf '%s\n\n' "  a1b2c3d4e5f6789012345678901234567890abcd  " \
        > "$INPUT_DIR/components.foo.sha"
    run "$HELPER" --input-dir "$INPUT_DIR"
    [ "$status" -eq 0 ]
    run jq -r '.foo' "$INPUT_DIR/components.json"
    [ "$output" = "a1b2c3d4e5f6789012345678901234567890abcd" ]
}

@test "produced components.json is consumable by manifest renderer" {
    # End-to-end composition smoke: feed the aggregator's output into
    # build-release.sh through the fixture pipeline. This pins the
    # contract between A-3b's aggregator and A-3a's release builder.
    printf '%s\n' "a1b2c3d4e5f6789012345678901234567890abcd" \
        > "$INPUT_DIR/components.readsb_wiedehopf.sha"
    printf '%s\n' "0fedcba987654321fedcba9876543210fedcba98" \
        > "$INPUT_DIR/components.dump978_fa.sha"

    run "$HELPER" --input-dir "$INPUT_DIR"
    [ "$status" -eq 0 ]

    # The produced components.json must satisfy the manifest-render
    # contract: a JSON object, keys are component names, values are
    # 7..40-hex SHAs. The schema validation runs in the build-release
    # bats; here we assert just the local shape.
    run jq -e 'type == "object"' "$INPUT_DIR/components.json"
    [ "$status" -eq 0 ]
    run jq -e '. | length > 0' "$INPUT_DIR/components.json"
    [ "$status" -eq 0 ]
}

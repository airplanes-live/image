#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/build-release.sh — assembles a release
# tree from a pre-staged input dir, renders manifest.json, and writes a
# deterministic SHA256SUMS. Each test runs against an in-tmpdir copy of the
# fixture input tree, rehydrated with the real overlay-source files (the
# .sh, .service, render-status files the fixture references) so the
# committed fixture stays small.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    BUILD="$REPO_ROOT/runtime-overlay/scripts/build-release.sh"
    VALIDATOR="$REPO_ROOT/runtime-overlay/scripts/validate-manifest.sh"
    FIXTURE_SRC="$REPO_ROOT/test/runtime-overlay/fixtures/build-release-input"

    [ -x "$BUILD" ]     || skip "build-release.sh not executable: $BUILD"
    [ -x "$VALIDATOR" ] || skip "validate-manifest.sh not executable: $VALIDATOR"
    [ -d "$FIXTURE_SRC" ] || skip "fixture missing: $FIXTURE_SRC"

    # Rehydrate the fixture: copy committed inputs (JSON snippets, stub
    # binaries, .gitkeep markers) plus the real overlay-source files the
    # manifest references. The .gitkeep placeholders only exist to make
    # empty fixture subdirs survive git; remove them before invoking the
    # build so the produced release tree doesn't ship them as payload.
    #
    # The destination dirs for the rehydrated overlay sources are also
    # created here rather than committed as empty dirs — git wouldn't
    # preserve them anyway, and `cp -a SRC/. DEST/` requires DEST to exist.
    INPUT_DIR="$BATS_TEST_TMPDIR/input"
    cp -a "$FIXTURE_SRC" "$INPUT_DIR"
    find "$INPUT_DIR" -name '.gitkeep' -type f -delete

    mkdir -p "$INPUT_DIR/share/airplanes" \
             "$INPUT_DIR/systemd" \
             "$INPUT_DIR/lib/airplanes" \
             "$INPUT_DIR/etc/lighttpd/conf-available" \
             "$INPUT_DIR/etc/update-motd.d"

    cp -a "$REPO_ROOT/runtime-overlay/src/share/airplanes/." \
          "$INPUT_DIR/share/airplanes/"
    cp -a "$REPO_ROOT/runtime-overlay/src/systemd/." \
          "$INPUT_DIR/systemd/"
    cp -a "$REPO_ROOT/runtime-overlay/src/lib/airplanes/." \
          "$INPUT_DIR/lib/airplanes/"
    cp -a "$REPO_ROOT/runtime-overlay/src/etc/lighttpd/conf-available/." \
          "$INPUT_DIR/etc/lighttpd/conf-available/"
    cp -a "$REPO_ROOT/runtime-overlay/src/etc/update-motd.d/." \
          "$INPUT_DIR/etc/update-motd.d/"

    OUTPUT_DIR="$BATS_TEST_TMPDIR/out"

    # Canonical args used by the happy-path and determinism tests. Tests
    # that want to mutate one argument copy the array and edit a single
    # slot.
    GOOD_ARGS=(
        --arch arm64
        --channel stable
        --version 1.4.0
        --commit-sha 0000000000000000000000000000000000000000
        --build-date 2026-05-20T12:00:00Z
        --input-dir "$INPUT_DIR"
        --output-dir "$OUTPUT_DIR"
    )
}

@test "happy path: produces the expected release tree" {
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -eq 0 ]

    [ -d "$OUTPUT_DIR/v1.4.0" ]
    [ -d "$OUTPUT_DIR/v1.4.0/bin" ]
    [ -d "$OUTPUT_DIR/v1.4.0/share/airplanes" ]
    [ -d "$OUTPUT_DIR/v1.4.0/share/tar1090" ]
    [ -d "$OUTPUT_DIR/v1.4.0/share/graphs1090" ]
    [ -d "$OUTPUT_DIR/v1.4.0/systemd" ]
    [ -d "$OUTPUT_DIR/v1.4.0/etc/lighttpd/conf-available" ]
    [ -d "$OUTPUT_DIR/v1.4.0/etc/update-motd.d" ]
    [ -d "$OUTPUT_DIR/v1.4.0/lib/airplanes" ]
    [ -d "$OUTPUT_DIR/v1.4.0/migrations" ]
    [ -f "$OUTPUT_DIR/v1.4.0/manifest.json" ]
    [ -f "$OUTPUT_DIR/v1.4.0/SHA256SUMS" ]
    [ -f "$OUTPUT_DIR/v1.4.0/bin/readsb" ]
    [ -x "$OUTPUT_DIR/v1.4.0/bin/readsb" ]
    [ -f "$OUTPUT_DIR/v1.4.0/bin/dump978-fa" ]
    [ -x "$OUTPUT_DIR/v1.4.0/bin/dump978-fa" ]

    # The input-only JSON snippets must NOT leak into the release tree.
    [ ! -f "$OUTPUT_DIR/v1.4.0/components.json" ]
    [ ! -f "$OUTPUT_DIR/v1.4.0/managed_paths.json" ]
    [ ! -f "$OUTPUT_DIR/v1.4.0/mutable_paths.json" ]
    [ ! -f "$OUTPUT_DIR/v1.4.0/systemd.json" ]
    [ ! -f "$OUTPUT_DIR/v1.4.0/migrations.json" ]
    [ ! -f "$OUTPUT_DIR/v1.4.0/compat.json" ]
}

@test "produced release tree contains no .gitkeep markers" {
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -eq 0 ]
    run find "$OUTPUT_DIR/v1.4.0" -name '.gitkeep'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rendered manifest passes the schema validator" {
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -eq 0 ]

    run "$VALIDATOR" "$OUTPUT_DIR/v1.4.0/manifest.json"
    [ "$status" -eq 0 ]
}

@test "manifest.json is world-readable (0644)" {
    # The on-device webconfig runs unprivileged and reads the manifest for
    # /api/status; mktemp's default 0600 would hide it. Non-secret provenance,
    # so 0644 like the image build-manifest.json.
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -eq 0 ]

    run stat -c '%a' "$OUTPUT_DIR/v1.4.0/manifest.json"
    [ "$status" -eq 0 ]
    [ "$output" = "644" ]
}

@test "SHA256SUMS verifies cleanly via sha256sum -c" {
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -eq 0 ]

    (
        cd "$OUTPUT_DIR/v1.4.0"
        sha256sum -c SHA256SUMS
    )
}

@test "SHA256SUMS excludes itself" {
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -eq 0 ]

    run grep -F SHA256SUMS "$OUTPUT_DIR/v1.4.0/SHA256SUMS"
    # grep exits 1 when there are zero matches; that's the desired outcome.
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "byte-deterministic across two runs with the same build-date" {
    # First build.
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -eq 0 ]

    # Second build into a different output dir.
    local out2="$BATS_TEST_TMPDIR/out2"
    local args2=("${GOOD_ARGS[@]}")
    args2[-1]="$out2"
    run "$BUILD" "${args2[@]}"
    [ "$status" -eq 0 ]

    run diff -r "$OUTPUT_DIR/v1.4.0" "$out2/v1.4.0"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "rejects --arch armhf" {
    local args=("${GOOD_ARGS[@]}")
    # Swap arch flag value to armhf.
    for i in "${!args[@]}"; do
        if [[ "${args[$i]}" == "--arch" ]]; then
            args[i+1]=armhf
            break
        fi
    done
    run "$BUILD" "${args[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"armhf"* ]]
}

@test "rejects a malformed --version" {
    local args=("${GOOD_ARGS[@]}")
    for i in "${!args[@]}"; do
        if [[ "${args[$i]}" == "--version" ]]; then
            args[i+1]="not-a-semver"
            break
        fi
    done
    run "$BUILD" "${args[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"version"* ]]
}

@test "rejects a missing --input-dir" {
    local args=("${GOOD_ARGS[@]}")
    for i in "${!args[@]}"; do
        if [[ "${args[$i]}" == "--input-dir" ]]; then
            args[i+1]="$BATS_TEST_TMPDIR/does-not-exist"
            break
        fi
    done
    run "$BUILD" "${args[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"input-dir"* ]]
}

@test "rejects --input-dir missing a required subdir" {
    # Remove the systemd subdir from the rehydrated input; build must fail.
    rm -rf "$INPUT_DIR/systemd"
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"systemd"* ]]
}

@test "rejects when a managed_paths.target points at a missing file" {
    # Delete a file the fixture's managed_paths.json references; the
    # cross-check inside the build must catch this before SHA256SUMS or
    # publish.
    rm "$INPUT_DIR/systemd/readsb.service"
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"managed_paths"* ]]
    [[ "$output" == *"readsb.service"* ]]
}

@test "leaves no partial release dir when validation fails" {
    # Same trigger as above. The build must clean up its staging tree
    # rather than leave a half-published v1.4.0 under output-dir.
    rm "$INPUT_DIR/systemd/readsb.service"
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -ne 0 ]
    [ ! -e "$OUTPUT_DIR/v1.4.0" ]
}

@test "manifest keys are canonically sorted at every nesting level" {
    run "$BUILD" "${GOOD_ARGS[@]}"
    [ "$status" -eq 0 ]

    # `jq -S` emits keys sorted lexicographically. Reformatting the rendered
    # manifest through `jq -S .` should yield byte-identical output if the
    # composer already used canonical ordering. `cmp -s` exits 0 only on
    # exact byte equality.
    local resorted="$BATS_TEST_TMPDIR/resorted.json"
    jq -S . "$OUTPUT_DIR/v1.4.0/manifest.json" > "$resorted"
    run cmp -s "$resorted" "$OUTPUT_DIR/v1.4.0/manifest.json"
    [ "$status" -eq 0 ]
}

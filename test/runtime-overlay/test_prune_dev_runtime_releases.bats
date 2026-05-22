#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/release-workflow/prune-dev-runtime-releases.sh.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/runtime-overlay/scripts/release-workflow/prune-dev-runtime-releases.sh"
    [ -x "$SCRIPT" ] || skip "prune-dev-runtime-releases.sh not executable"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

fixture_json() {
    cat <<'JSON'
[
  {"tagName":"runtime-dev-latest","createdAt":"2026-04-01T00:00:00Z"},
  {"tagName":"runtime-v1.0.0","createdAt":"2026-04-01T00:00:00Z"},
  {"tagName":"runtime-dev-20260522-aaaaaaa","createdAt":"2026-05-22T00:00:00Z"},
  {"tagName":"runtime-dev-20260521-bbbbbbb","createdAt":"2026-05-21T00:00:00Z"},
  {"tagName":"runtime-dev-20260520-ccccccc","createdAt":"2026-05-20T00:00:00Z"},
  {"tagName":"runtime-dev-20260501-ddddddd","createdAt":"2026-05-01T00:00:00Z"},
  {"tagName":"runtime-dev-20260430-eeeeeee","createdAt":"2026-04-30T00:00:00Z"}
]
JSON
}

@test "dry run keeps newest, recent, and protected immutable dev releases" {
    now_epoch="$(date -u -d '2026-05-22T00:00:00Z' +%s)"

    RUNTIME_DEV_RELEASES_JSON="$(fixture_json)" \
    RUNTIME_DEV_RELEASE_NOW_EPOCH="$now_epoch" \
    RUNTIME_DEV_RELEASE_KEEP_COUNT=2 \
    RUNTIME_DEV_RELEASE_KEEP_DAYS=7 \
    RUNTIME_DEV_RELEASE_DRY_RUN=true \
        run "$SCRIPT" --repo airplanes-live/image \
            --protected-tag runtime-dev-20260501-ddddddd

    [ "$status" -eq 0 ]
    [[ "$output" == *"keep   runtime-dev-20260522-aaaaaaa"* ]]
    [[ "$output" == *"keep   runtime-dev-20260521-bbbbbbb"* ]]
    [[ "$output" == *"keep   runtime-dev-20260520-ccccccc"* ]]
    [[ "$output" == *"keep   runtime-dev-20260501-ddddddd"* ]]
    [[ "$output" == *"delete runtime-dev-20260430-eeeeeee"* ]]
    [[ "$output" == *"Dry run only; would delete 1 release(s)."* ]]
    [[ "$output" != *"runtime-dev-latest ("* ]]
    [[ "$output" != *"runtime-v1.0.0 ("* ]]
}

@test "non-dry run deletes selected releases with cleanup-tag" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
STUB
    chmod 0755 "$BATS_TEST_TMPDIR/bin/gh"

    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    now_epoch="$(date -u -d '2026-05-22T00:00:00Z' +%s)"

    RUNTIME_DEV_RELEASES_JSON='[
      {"tagName":"runtime-dev-20260430-eeeeeee","createdAt":"2026-04-30T00:00:00Z"}
    ]' \
    RUNTIME_DEV_RELEASE_NOW_EPOCH="$now_epoch" \
    RUNTIME_DEV_RELEASE_KEEP_COUNT=0 \
    RUNTIME_DEV_RELEASE_KEEP_DAYS=0 \
    RUNTIME_DEV_RELEASE_DRY_RUN=false \
        run "$SCRIPT" --repo airplanes-live/image

    [ "$status" -eq 0 ]
    run grep -F "release delete runtime-dev-20260430-eeeeeee -R airplanes-live/image --yes --cleanup-tag" "$GH_LOG"
    [ "$status" -eq 0 ]
}

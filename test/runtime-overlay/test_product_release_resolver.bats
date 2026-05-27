#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    LIB="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh"
    [ -r "$LIB" ] || skip "install-common.sh missing"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

@test "stable resolver selects latest published product release with runtime assets" {
    stub="$BATS_TEST_TMPDIR/bin/curl"
    mkdir -p "$(dirname "$stub")"
    cat > "$stub" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
[
  {
    "tag_name": "v1.0.0",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "runtime-overlay-arm64.tar.gz"},
      {"name": "runtime-manifest.json"},
      {"name": "runtime-SHA256SUMS"},
      {"name": "runtime-SHA256SUMS.minisig"}
    ]
  },
  {
    "tag_name": "v1.2.0",
    "draft": true,
    "prerelease": false,
    "assets": [
      {"name": "runtime-overlay-arm64.tar.gz"},
      {"name": "runtime-manifest.json"},
      {"name": "runtime-SHA256SUMS"},
      {"name": "runtime-SHA256SUMS.minisig"}
    ]
  },
  {
    "tag_name": "v1.1.0",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "runtime-overlay-arm64.tar.gz"},
      {"name": "runtime-manifest.json"},
      {"name": "runtime-SHA256SUMS"},
      {"name": "runtime-SHA256SUMS.minisig"}
    ]
  },
  {
    "tag_name": "v2.0.0",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "airplanes-feeder-stable-arm64.img.xz"}
    ]
  }
]
JSON
SH
    chmod 755 "$stub"

    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
        AIRPLANES_RUNTIME_RELEASES_API="https://example.invalid/releases" \
        bash -c ". '$LIB'; airplanes_runtime_resolve_latest_stable_tag"
    [ "$status" -eq 0 ]
    [ "$output" = "v1.1.0" ]
}

@test "dev resolver returns product dev-latest tag" {
    run bash -c ". '$LIB'; airplanes_runtime_resolve_dev_latest_tag"
    [ "$status" -eq 0 ]
    [ "$output" = "dev-latest" ]
}

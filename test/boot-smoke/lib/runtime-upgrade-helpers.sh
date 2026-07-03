#!/usr/bin/env bash
# Host-side helpers for the runtime-overlay-upgrade variant of the image boot
# smoke. Builds SYNTHETIC local overlay releases (a GOOD vN+1 and a BROKEN
# vN+1) from the just-built runtime-overlay tree, signs them with a throwaway
# minisign key, and stages them into the rootfs together with that key's pubkey
# so the in-VM runtime-self-update.sh trusts and installs them WITHOUT touching
# any real GitHub release.
#
# Split in two:
#   - build_synthetic_runtime_releases_prebuild: runs OUTSIDE the sudo harness
#     on the CI runner. Re-stamps the built overlay tree to a higher version,
#     repacks + re-signs as GOOD, then derives a BROKEN variant whose decoder
#     binary starts but never passes the health gate. Emits good/ and broken/
#     asset-set dirs plus the test minisign pubkey.
#   - install_synthetic_runtime_releases: runs INSIDE the sudo harness from
#     test/boot-smoke/setup.sh. Copies the asset sets + the test pubkey onto
#     $ROOT and overrides the baked runtime-release pubkey so the synthetic
#     releases verify on-device.
#
# The in-VM probe (extra-probe.sh, AIRPLANES_BOOT_SMOKE_TEST_RUNTIME_UPGRADE=1)
# drives runtime-self-update.sh against the staged local asset dir twice (GOOD
# then BROKEN) via AIRPLANES_RUNTIME_RELEASE_ASSET_DIR, asserting convergence
# then rollback, and reboots to confirm persistence.

# build_synthetic_runtime_releases_prebuild SIGNED_ASSET_DIR OVERLAY_DIR OUT_DIR
#
# SIGNED_ASSET_DIR  the runtime-assets-signed-arm64 artifact dir (carries
#                   runtime-overlay-arm64.tar.gz + runtime-manifest.json).
# OVERLAY_DIR       the runtime-overlay source dir (for build-release.sh,
#                   pack-release-tarball.sh).
# OUT_DIR           output dir; populated with good/, broken/, and test.pub.
build_synthetic_runtime_releases_prebuild() {
    local signed_dir="$1"
    local overlay_dir="$2"
    local out_dir="$3"

    [[ -d "$signed_dir" ]] || { echo "ERROR: signed asset dir missing: $signed_dir" >&2; return 1; }
    local base_tarball="$signed_dir/runtime-overlay-arm64.tar.gz"
    local base_manifest="$signed_dir/runtime-manifest.json"
    [[ -f "$base_tarball" ]]  || { echo "ERROR: base tarball missing: $base_tarball" >&2; return 1; }
    [[ -f "$base_manifest" ]] || { echo "ERROR: base manifest missing: $base_manifest" >&2; return 1; }
    command -v minisign >/dev/null || { echo "ERROR: minisign not on PATH" >&2; return 1; }
    command -v jq >/dev/null || { echo "ERROR: jq not on PATH" >&2; return 1; }

    rm -rf "$out_dir"
    install -d -m 0755 "$out_dir"

    # Throwaway minisign keypair. The pubkey is baked into the test image; the
    # privkey signs the synthetic releases and never leaves the runner.
    local sec="$out_dir/test.sec"
    local pub="$out_dir/test.pub"
    echo "" | minisign -G -p "$pub" -s "$sec" -W >/dev/null 2>&1 \
        || { echo "ERROR: minisign keygen failed" >&2; return 1; }

    # Derive the base version + channel from the built manifest, then bump to a
    # synthetic higher version so the same-version-replay guard does not trip.
    local base_version channel
    base_version="$(jq -r '.version' "$base_manifest")"
    channel="$(jq -r '.channel' "$base_manifest")"

    # Unpack the base release tree once; both synthetic releases derive from it.
    local base_tree="$out_dir/.base-tree"
    install -d -m 0755 "$base_tree"
    tar -xzf "$base_tarball" -C "$base_tree" --strip-components=1

    # GOOD: re-stamp to a synthetic higher version. BROKEN: same, plus corrupt
    # readsb so the unit starts but the health gate never passes.
    _rt_build_release "$overlay_dir" "$channel" "$base_tree" "$out_dir/good" good \
        || return 1
    _rt_build_release "$overlay_dir" "$channel" "$base_tree" "$out_dir/broken" broken \
        || return 1

    _rt_sign_asset_set "$out_dir/good" "$sec" "$pub"   || return 1
    _rt_sign_asset_set "$out_dir/broken" "$sec" "$pub" || return 1

    rm -f "$sec"
    echo "runtime-upgrade-helpers: built synthetic releases (base=$base_version channel=$channel) → $out_dir"
}

# _rt_synthetic_version CHANNEL VARIANT — derive a synthetic version string the
# manifest schema accepts. stable wants X.Y.Z; dev wants X.Y.Z-dev-YYYYMMDD-sha.
# good and broken use DIFFERENT versions so the second (broken) install is not
# rejected as a same-version replay of the first.
_rt_synthetic_version() {
    local channel="$1" variant="$2"
    local patch
    case "$variant" in
        good)   patch=99 ;;
        broken) patch=100 ;;
        *)      patch=98 ;;
    esac
    case "$channel" in
        stable) printf '9.9.%s' "$patch" ;;
        dev)    printf '9.9.%s-dev-20240101-deadbee' "$patch" ;;
        *)      printf '9.9.%s' "$patch" ;;
    esac
}

# _rt_build_release OVERLAY_DIR CHANNEL BASE_TREE OUT VARIANT — repack the base
# tree at a synthetic version into an asset-set dir (tarball + manifest). For
# the broken variant, replace the readsb binary with a stub that starts but
# never serves so the health gate exhausts and rollback fires.
_rt_build_release() {
    local overlay_dir="$1" channel="$2" base_tree="$3" out="$4" variant="$5"
    local version
    version="$(_rt_synthetic_version "$channel" "$variant")"

    local work
    work="$(mktemp -d)"
    cp -a "$base_tree/." "$work/"

    # build-release.sh renders the manifest from JSON snippets in the input dir
    # (components.json, managed_paths.json, mutable_paths.json, systemd.json,
    # migrations.json, compat.json). The published release tree does NOT carry
    # those snippets (they are stripped at publish), only the rendered
    # manifest.json. Reconstruct each snippet from the base manifest so
    # build-release can re-render a structurally identical manifest at the new
    # version.
    local base_mf="$base_tree/manifest.json"
    jq -S '.components'    "$base_mf" > "$work/components.json"
    jq -S '.managed_paths' "$base_mf" > "$work/managed_paths.json"
    jq -S '.mutable_paths' "$base_mf" > "$work/mutable_paths.json"
    jq -S '.systemd'       "$base_mf" > "$work/systemd.json"
    jq -S '.migrations'    "$base_mf" > "$work/migrations.json"
    jq -S '(.compat // {})' "$base_mf" > "$work/compat.json"

    # The release tree carries its own manifest.json + SHA256SUMS; build-release
    # regenerates both from the input dir. Drop the stale ones so build-release
    # re-renders cleanly.
    rm -f "$work/manifest.json" "$work/SHA256SUMS" "$work/PROVENANCE.md"

    if [[ "$variant" == "broken" ]]; then
        # Stub readsb: execs, accepts any args, never writes aircraft.json and
        # never binds — the readsb unit reaches "active" briefly but the health
        # gate's freshness/HTTP probes never pass, driving rollback. A stub that
        # exits immediately would instead fail at `systemctl restart`, which
        # exercises a different (systemd-ops) branch; we want the health-gate
        # rollback path, so the stub sleeps.
        cat > "$work/bin/readsb" <<'STUB'
#!/bin/sh
trap 'exit 0' TERM
while :; do sleep 30; done
STUB
        chmod 0755 "$work/bin/readsb"
    fi

    install -d -m 0755 "$out"
    local release_root="$out/tree"
    install -d -m 0755 "$release_root"

    bash "$overlay_dir/scripts/build-release.sh" \
        --arch arm64 \
        --channel "$channel" \
        --version "$version" \
        --commit-sha 0000000000000000000000000000000000000000 \
        --build-date 2024-01-01T00:00:00Z \
        --input-dir "$work" \
        --output-dir "$release_root" \
        || { echo "ERROR: build-release ($variant $version) failed" >&2; rm -rf "$work"; return 1; }

    local release_dir="$release_root/v$version"
    bash "$overlay_dir/scripts/release-workflow/pack-release-tarball.sh" \
        --release-dir "$release_dir" \
        --output "$out/runtime-overlay-arm64.tar.gz" \
        || { echo "ERROR: pack-release-tarball ($variant) failed" >&2; rm -rf "$work"; return 1; }

    cp -- "$release_dir/manifest.json" "$out/runtime-manifest.json"
    : > "$out/runtime-PROVENANCE.md"
    rm -rf "$work" "$release_root"
}

# _rt_sign_asset_set OUT SEC PUB — write runtime-SHA256SUMS over the asset set
# and sign it with the throwaway key. Mirrors the production sign-runtime job's
# SHA256SUMS + minisig layout the on-device updater verifies.
_rt_sign_asset_set() {
    local out="$1" sec="$2" pub="$3"
    (
        cd "$out" || exit 1
        sha256sum \
            runtime-overlay-arm64.tar.gz \
            runtime-manifest.json \
            runtime-PROVENANCE.md \
            | LC_ALL=C sort -k2 > runtime-SHA256SUMS
        echo "" | minisign -Sm runtime-SHA256SUMS \
            -s "$sec" -W -x runtime-SHA256SUMS.minisig >/dev/null 2>&1
    ) || { echo "ERROR: signing asset set in $out failed" >&2; return 1; }
    # Sanity: verify the signature with the matching pubkey before shipping.
    minisign -V -p "$pub" -x "$out/runtime-SHA256SUMS.minisig" -m "$out/runtime-SHA256SUMS" \
        >/dev/null 2>&1 || { echo "ERROR: self-verify of $out failed" >&2; return 1; }
}

# install_synthetic_runtime_releases ROOT PREBUILT_DIR
#
# Runs INSIDE the sudo harness. Copies the good/broken asset sets + the test
# pubkey onto $ROOT and overrides the baked runtime-release pubkey so the
# synthetic releases verify on-device. The in-VM probe points
# AIRPLANES_RUNTIME_RELEASE_ASSET_DIR at the staged good/broken dirs.
install_synthetic_runtime_releases() {
    local root="$1"
    local prebuilt="$2"

    [[ -d "$root" ]] || { echo "ERROR: rootfs $root missing" >&2; return 1; }
    [[ -d "$prebuilt/good" && -d "$prebuilt/broken" ]] || {
        echo "ERROR: prebuilt dir $prebuilt missing good/ or broken/" >&2; return 1; }
    [[ -f "$prebuilt/test.pub" ]] || {
        echo "ERROR: prebuilt dir $prebuilt missing test.pub" >&2; return 1; }

    local staged_in_image=/opt/airplanes-test-releases
    local staged_host="$root$staged_in_image"
    rm -rf "$staged_host"
    install -d -m 0755 "$staged_host"
    cp -a "$prebuilt/good"   "$staged_host/good"
    cp -a "$prebuilt/broken" "$staged_host/broken"

    # Override the baked runtime-release pubkey so the synthetic releases (signed
    # by the throwaway key) verify. The production / PR-test pubkey is replaced
    # entirely; this is a test-only image.
    install -d -m 0755 "$root/usr/share/airplanes"
    install -m 0644 "$prebuilt/test.pub" "$root/opt/airplanes/libexec/runtime-release.pub"

    # Run readsb net-only on this test image. The runtime-self-update health
    # gate requires readsb.service to reach AND hold active (NRestarts
    # unchanged across the stability window) before it declares an update
    # converged. readsb.sh defaults DUMP1090=yes, which makes readsb open an
    # RTL-SDR; QEMU has none, so readsb exits 1 and Restart=always loops it
    # forever. The gate then correctly rolls the GOOD release back — there is
    # no SDR for it to converge against. Baseline boot-smoke tolerates this
    # only because its own probes deliberately exclude readsb (no-SDR is
    # expected there); the real health gate cannot make that exception without
    # weakening production rollback.
    #
    # DUMP1090=no flips readsb.sh to --net-only: it binds its loopback ports,
    # writes /run/readsb/aircraft.json every 0.5s, and stays active with zero
    # restarts — a legitimate network-input feeder posture, not a stubbed
    # decoder. The unit-active, aircraft.json-freshness, and tar1090 HTTP gates
    # all then pass against the REAL readsb binary, so the GOOD case converges
    # while every other gate (webconfig + feed identity/health) stays real.
    # The BROKEN release is unaffected: its stubbed readsb sleeps forever and
    # never writes aircraft.json, so the freshness gate still fails and
    # rollback still fires.
    #
    # merge_feed_env in airplanes-first-run only rewrites the boot-config-
    # derived keys (MLATSERVER, TARGET); it copies every other line verbatim,
    # so this seeded DUMP1090=no survives first boot.
    install -d -m 0755 "$root/etc/airplanes"
    if [[ -f "$root/etc/airplanes/feed.env" ]] \
            && grep -qE '^DUMP1090=' "$root/etc/airplanes/feed.env"; then
        sed -i 's/^DUMP1090=.*/DUMP1090=no/' "$root/etc/airplanes/feed.env"
    else
        printf 'DUMP1090=no\n' >> "$root/etc/airplanes/feed.env"
    fi

    # Marker consumed by extra-probe.sh to enter the runtime-upgrade path.
    install -d -m 0755 "$root/var/lib/airplanes-boot-smoke"
    printf '%s' "$staged_in_image" > "$root/var/lib/airplanes-boot-smoke/runtime-upgrade-asset-base"

    echo "runtime-upgrade-helpers: staged $staged_in_image + test pubkey (readsb pinned net-only via DUMP1090=no)"
}

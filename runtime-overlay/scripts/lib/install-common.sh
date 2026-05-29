# shellcheck shell=bash
#
# install-common.sh — shared helpers for the runtime overlay's on-device
# install/update path.
#
# Sourced by:
#   - runtime-overlay/install.sh                              (build mode + runtime mode)
#   - runtime-overlay/update.sh                               (runtime mode shim)
#   - runtime-overlay/src/lib/runtime-self-update.sh          (state-machine wrapper)
#
# Boot-time recovery is NOT sourced from here. It is an image-owned POSIX-sh
# pointer shim (/usr/local/lib/airplanes-runtime/recover-shim) that uses only
# base-OS tools so it survives a fully broken overlay — see the image stage
# at stage-airplanes/02-install-runtime-overlay/.
#
# Naming: every function declared here is `airplanes_runtime_*`. Variables that
# the caller may override (download base, repo URL, lock path, etc.) are
# uppercase AIRPLANES_RUNTIME_* env vars with safe defaults.
#
# Dependencies on the Pi: bash >= 5, coreutils, git (for ls-remote), curl,
# tar, sha256sum, python3, jq, minisign, flock. minisign is added to stage 00
# (build-time) and present in apt's bookworm/trixie default repos.

# ---------------------------------------------------------------------------
# Defaults and tunables
# ---------------------------------------------------------------------------

# Version of THIS updater. A release whose manifest declares an
# installer_min_version greater than this is refused before any mutation —
# old updaters that cannot understand a newer manifest hard-fail cleanly
# rather than half-installing. Bump this when the updater gains a capability a
# future release will declare a floor against. Overridable for tests.
AIRPLANES_RUNTIME_INSTALLER_VERSION="${AIRPLANES_RUNTIME_INSTALLER_VERSION:-1.0.0}"

# Schema version this updater understands. A manifest declaring a higher
# manifest_schema_version is refused before mutation (forward-compat floor).
AIRPLANES_RUNTIME_INSTALLER_SCHEMA_VERSION="${AIRPLANES_RUNTIME_INSTALLER_SCHEMA_VERSION:-1}"

# Minimum free bytes required on the releases filesystem before extraction.
# Default 250MB headroom covers the decoder tree plus retained releases on a
# small SD card; overridable for tests and tuning.
AIRPLANES_RUNTIME_MIN_FREE_BYTES="${AIRPLANES_RUNTIME_MIN_FREE_BYTES:-262144000}"

AIRPLANES_RUNTIME_REPO="${AIRPLANES_RUNTIME_REPO:-https://github.com/airplanes-live/image.git}"
AIRPLANES_RUNTIME_DOWNLOAD_BASE="${AIRPLANES_RUNTIME_DOWNLOAD_BASE:-https://github.com/airplanes-live/image/releases/download}"
AIRPLANES_RUNTIME_RELEASES_API="${AIRPLANES_RUNTIME_RELEASES_API:-https://api.github.com/repos/airplanes-live/image/releases}"
AIRPLANES_RUNTIME_RELEASE_ASSET_DIR="${AIRPLANES_RUNTIME_RELEASE_ASSET_DIR:-}"

# Probe URL base for the in-process HTTP gates. The default targets the
# loopback lighttpd reverse proxy on the feeder; the bats tests override it
# to a python -m http.server fixture on a random port.
AIRPLANES_RUNTIME_PROBE_URL_BASE="${AIRPLANES_RUNTIME_PROBE_URL_BASE:-http://127.0.0.1}"

# Minisign public key used to verify SHA256SUMS. Ships in the image at
# /usr/share/airplanes/runtime-release.pub (stage 00). Tests point this at a
# tmpdir fixture.
AIRPLANES_RUNTIME_MINISIGN_PUBKEY="${AIRPLANES_RUNTIME_MINISIGN_PUBKEY:-/usr/share/airplanes/runtime-release.pub}"

# Filesystem root for the runtime overlay tree. Build mode rebases this under
# $ROOTFS_DIR; runtime mode uses /. Tests rebase it under a tmpdir so
# install steps land under a controlled root.
AIRPLANES_RUNTIME_ROOT="${AIRPLANES_RUNTIME_ROOT:-/}"

# Per-check deadline used by the health gates (seconds).
AIRPLANES_RUNTIME_HEALTH_DEADLINE="${AIRPLANES_RUNTIME_HEALTH_DEADLINE:-120}"

# Number of historical releases to keep under /opt/airplanes-runtime/releases/
# after a successful install (in addition to the new current). 2 = keep one
# prior release for fast rollback.
AIRPLANES_RUNTIME_RETAIN_RELEASES="${AIRPLANES_RUNTIME_RETAIN_RELEASES:-2}"

# Persistent record of forward-completed migration ids. Used to honour
# `run_when: first_install_of_version`. Path is rebased through TARGET_ROOT
# in the per-function callers, so this is just the absolute suffix.
AIRPLANES_RUNTIME_MIGRATIONS_APPLIED_REL="etc/airplanes/runtime-migrations.applied"

# ---------------------------------------------------------------------------
# Mode detection and target-root resolution
# ---------------------------------------------------------------------------

airplanes_runtime_is_build_mode() {
    [[ "${AIRPLANES_BUILD_MODE:-0}" == "1" \
        || "${AIRPLANES_BUILD_MODE:-}" == "true" \
        || "${AIRPLANES_BUILD_MODE:-}" == "yes" ]]
}

airplanes_runtime_parse_mode_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --build-mode)
                AIRPLANES_BUILD_MODE=1
                export AIRPLANES_BUILD_MODE
                ;;
            --runtime)
                AIRPLANES_BUILD_MODE=0
                export AIRPLANES_BUILD_MODE
                ;;
        esac
    done
}

# Emits the absolute filesystem prefix that subsequent operations should
# rebase against. The result is either "" (mapping to /) or a path with no
# trailing slash so callers can concatenate `${root}/etc/...` without
# producing `//etc/...`.
airplanes_runtime_target_root() {
    if airplanes_runtime_is_build_mode; then
        printf '%s' "${ROOTFS_DIR:?ROOTFS_DIR must be set in build mode}"
        return 0
    fi
    printf '%s' "${AIRPLANES_RUNTIME_ROOT%/}"
}

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------
#
# v1 of the runtime overlay is arm64-only (decision 15). Build mode honours
# pi-gen's ${ARCH}; runtime mode reads `uname -m`. Anything else is rejected
# loudly so the user sees a real diagnostic instead of a generic asset-404
# from the download step.

airplanes_runtime_detect_arch() {
    # Test-only override. Production paths leave this unset and fall
    # through to the build-mode / uname branches.
    if [[ -n "${AIRPLANES_RUNTIME_ARCH_OVERRIDE:-}" ]]; then
        case "${AIRPLANES_RUNTIME_ARCH_OVERRIDE}" in
            arm64) printf '%s' "arm64"; return 0 ;;
            *)
                echo "ERROR: AIRPLANES_RUNTIME_ARCH_OVERRIDE must be arm64 (got: $AIRPLANES_RUNTIME_ARCH_OVERRIDE)" >&2
                return 1
                ;;
        esac
    fi

    if airplanes_runtime_is_build_mode; then
        case "${ARCH:-}" in
            arm64) printf '%s' "arm64"; return 0 ;;
            "") echo "ERROR: ARCH must be set by pi-gen in build mode" >&2; return 1 ;;
            *)
                echo "ERROR: unsupported build-mode ARCH='${ARCH}' (runtime overlay is arm64-only at v1)" >&2
                return 1
                ;;
        esac
    fi

    case "$(uname -m)" in
        aarch64) printf '%s' "arm64" ;;
        *)
            echo "ERROR: unsupported architecture '$(uname -m)' (runtime overlay is arm64-only at v1)" >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Channel and tag resolution
# ---------------------------------------------------------------------------
#
# Build mode normally receives AIRPLANES_RUNTIME_RELEASE_ASSET_DIR from CI and
# consumes a just-built signed runtime asset set before it is published. Local
# builds can still set AIRPLANES_RUNTIME_OVERLAY_TAG to force a concrete
# product release tag. Runtime mode reads /etc/airplanes/release-channel.

airplanes_runtime_resolve_channel() {
    if airplanes_runtime_is_build_mode; then
        if [[ -n "${AIRPLANES_RUNTIME_OVERLAY_TAG:-}" || -n "${AIRPLANES_RUNTIME_RELEASE_ASSET_DIR:-}" ]]; then
            printf '%s' "pinned"
            return 0
        fi
        case "${CHANNEL:-}" in
            stable|dev)
                printf '%s' "$CHANNEL"
                ;;
            *)
                echo "ERROR: build mode requires AIRPLANES_RUNTIME_RELEASE_ASSET_DIR, AIRPLANES_RUNTIME_OVERLAY_TAG, or CHANNEL=stable|dev" >&2
                return 1
                ;;
        esac
        return 0
    fi

    # Runtime: when the operator (or the test harness) has pinned a tag
    # explicitly via env, honour it and skip the channel-file resolution.
    # This is the operator-triage escape hatch and the test fixture path.
    if [[ -n "${AIRPLANES_RUNTIME_OVERLAY_TAG:-}" ]]; then
        printf '%s' "pinned"
        return 0
    fi

    local channel_file
    channel_file="$(airplanes_runtime_target_root)/etc/airplanes/release-channel"
    if [[ ! -r "$channel_file" ]]; then
        printf '%s' "stable"
        return 0
    fi
    local channel
    channel="$(head -n1 "$channel_file" | tr -d '[:space:]')"
    case "$channel" in
        stable|main) printf '%s' "stable" ;;
        dev)         printf '%s' "dev" ;;
        *)
            echo "ERROR: $channel_file contains '$channel' (expected: stable, dev, main)" >&2
            return 1
            ;;
    esac
}

# Resolves a channel name into a concrete product release tag. Stable picks the
# highest published non-draft, non-prerelease vMAJOR.MINOR.PATCH release that
# carries runtime assets. Dev returns the floating `dev-latest` prerelease.
airplanes_runtime_resolve_tag() {
    local channel="$1"
    case "$channel" in
        stable)
            airplanes_runtime_resolve_latest_stable_tag
            ;;
        dev)
            airplanes_runtime_resolve_dev_latest_tag
            ;;
        pinned)
            if [[ -n "${AIRPLANES_RUNTIME_OVERLAY_TAG:-}" ]]; then
                printf '%s' "${AIRPLANES_RUNTIME_OVERLAY_TAG}"
                return 0
            fi
            if [[ -n "${AIRPLANES_RUNTIME_RELEASE_ASSET_DIR:-}" ]]; then
                printf '%s' "local-assets"
                return 0
            fi
            echo "ERROR: pinned channel selected but no runtime release source is set" >&2
            return 1
            ;;
        *)
            printf '%s' "$channel"
            ;;
    esac
}

airplanes_runtime_release_has_product_runtime_assets_jq() {
    cat <<'JQ'
def has_asset($name): any(.assets[]?; .name == $name);
[
  .[]?
  | select((.draft // false) | not)
  | select((.prerelease // false) | not)
  | select(.tag_name | test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
  | select(has_asset("runtime-overlay-arm64.tar.gz"))
  | select(has_asset("runtime-manifest.json"))
  | select(has_asset("runtime-SHA256SUMS"))
  | select(has_asset("runtime-SHA256SUMS.minisig"))
  | .tag_name
]
| sort_by(sub("^v"; "") | split(".") | map(tonumber))
| last // ""
JQ
}

# Strict match: vMAJOR.MINOR.PATCH, no leading zeroes, no prereleases. The
# query uses the Releases API rather than raw git tags so a pushed tag does not
# become available to devices before CI has published signed runtime assets.
airplanes_runtime_resolve_latest_stable_tag() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: required dependency 'jq' not found on PATH" >&2
        return 1
    fi

    local url="${AIRPLANES_RUNTIME_RELEASES_API}?per_page=100"
    local releases
    if ! releases="$(curl -fsSL --max-time 120 "$url" 2>/dev/null)"; then
        echo "ERROR: could not query product releases from $AIRPLANES_RUNTIME_RELEASES_API (network/DNS/TLS failure)" >&2
        return 2
    fi

    local jq_filter latest
    jq_filter="$(airplanes_runtime_release_has_product_runtime_assets_jq)"
    if ! latest="$(jq -r "$jq_filter" <<<"$releases")"; then
        echo "ERROR: could not parse product releases from $AIRPLANES_RUNTIME_RELEASES_API" >&2
        return 1
    fi
    if [[ -z "$latest" || "$latest" == "null" ]]; then
        echo "ERROR: stable channel selected but no published vX.Y.Z release with runtime assets exists at $AIRPLANES_RUNTIME_RELEASES_API" >&2
        return 1
    fi
    printf '%s' "$latest"
}

airplanes_runtime_resolve_dev_latest_tag() {
    printf '%s' "dev-latest"
}

airplanes_runtime_product_tarball_name() {
    local arch="$1"
    printf 'runtime-overlay-%s.tar.gz' "$arch"
}

airplanes_runtime_downloaded_tarball_name_file() {
    local dest_dir="$1"
    printf '%s/.runtime-tarball-name' "$dest_dir"
}

airplanes_runtime_downloaded_manifest_name_file() {
    local dest_dir="$1"
    printf '%s/.runtime-manifest-name' "$dest_dir"
}

airplanes_runtime_downloaded_tarball_path() {
    local arch="$1" dest_dir="$2"
    local name_file name
    name_file="$(airplanes_runtime_downloaded_tarball_name_file "$dest_dir")"
    if [[ -r "$name_file" ]]; then
        name="$(head -n1 "$name_file")"
    else
        name="$(airplanes_runtime_product_tarball_name "$arch")"
    fi
    printf '%s/%s' "$dest_dir" "$name"
}

airplanes_runtime_stage_asset_set_from_dir() {
    local src_dir="$1" arch="$2" dest_dir="$3"
    local tarball_name manifest_name sums_name sig_name provenance_name

    tarball_name="$(airplanes_runtime_product_tarball_name "$arch")"
    manifest_name="runtime-manifest.json"
    sums_name="runtime-SHA256SUMS"
    sig_name="runtime-SHA256SUMS.minisig"
    provenance_name="runtime-PROVENANCE.md"

    local f
    for f in "$tarball_name" "$manifest_name" "$sums_name" "$sig_name"; do
        [[ -f "$src_dir/$f" ]] || return 1
    done

    cp -- "$src_dir/$tarball_name" "$dest_dir/$tarball_name"
    cp -- "$src_dir/$manifest_name" "$dest_dir/$manifest_name"
    cp -- "$src_dir/$sums_name" "$dest_dir/SHA256SUMS"
    cp -- "$src_dir/$sig_name" "$dest_dir/SHA256SUMS.minisig"
    if [[ -f "$src_dir/$provenance_name" ]]; then
        cp -- "$src_dir/$provenance_name" "$dest_dir/PROVENANCE.md"
    else
        : > "$dest_dir/PROVENANCE.md"
    fi

    printf '%s\n' "$tarball_name" > "$(airplanes_runtime_downloaded_tarball_name_file "$dest_dir")"
    printf '%s\n' "$manifest_name" > "$(airplanes_runtime_downloaded_manifest_name_file "$dest_dir")"
}

airplanes_runtime_download_asset_set_from_release() {
    local tag="$1" arch="$2" dest_dir="$3"
    local tarball_name manifest_name sums_name sig_name provenance_name

    tarball_name="$(airplanes_runtime_product_tarball_name "$arch")"
    manifest_name="runtime-manifest.json"
    sums_name="runtime-SHA256SUMS"
    sig_name="runtime-SHA256SUMS.minisig"
    provenance_name="runtime-PROVENANCE.md"

    local base="${AIRPLANES_RUNTIME_DOWNLOAD_BASE}/${tag}"
    local tmp
    tmp="$(mktemp -d "$dest_dir/.download.XXXXXX")"

    local remote local_name
    for remote in "$tarball_name" "$manifest_name" "$sums_name" "$sig_name"; do
        local_name="$remote"
        [[ "$remote" == "$sums_name" ]] && local_name="SHA256SUMS"
        [[ "$remote" == "$sig_name" ]] && local_name="SHA256SUMS.minisig"
        if ! curl -fsSL --max-time 120 -o "$tmp/$local_name" "$base/$remote"; then
            rm -rf -- "$tmp"
            return 1
        fi
    done

    if ! curl -fsSL --max-time 120 -o "$tmp/PROVENANCE.md" "$base/$provenance_name"; then
        : > "$tmp/PROVENANCE.md"
    fi

    mv -- "$tmp"/* "$dest_dir/"
    rm -rf -- "$tmp"
    printf '%s\n' "$tarball_name" > "$(airplanes_runtime_downloaded_tarball_name_file "$dest_dir")"
    printf '%s\n' "$manifest_name" > "$(airplanes_runtime_downloaded_manifest_name_file "$dest_dir")"
}

# ---------------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------------
#
# Product releases publish fixed runtime asset names:
#   runtime-overlay-<arch>.tar.gz
#   runtime-manifest.json
#   runtime-SHA256SUMS
#   runtime-SHA256SUMS.minisig
#   runtime-PROVENANCE.md
airplanes_runtime_download_release() {
    local tag="$1" arch="$2" dest_dir="$3"

    install -d -m 755 "$dest_dir"

    if [[ -n "${AIRPLANES_RUNTIME_RELEASE_ASSET_DIR:-}" ]]; then
        if [[ ! -d "$AIRPLANES_RUNTIME_RELEASE_ASSET_DIR" ]]; then
            echo "ERROR: AIRPLANES_RUNTIME_RELEASE_ASSET_DIR is not a directory: $AIRPLANES_RUNTIME_RELEASE_ASSET_DIR" >&2
            return 1
        fi
        if ! airplanes_runtime_stage_asset_set_from_dir "$AIRPLANES_RUNTIME_RELEASE_ASSET_DIR" "$arch" "$dest_dir"; then
            echo "ERROR: no complete product runtime asset set found in $AIRPLANES_RUNTIME_RELEASE_ASSET_DIR" >&2
            return 1
        fi
    else
        if ! airplanes_runtime_download_asset_set_from_release "$tag" "$arch" "$dest_dir"; then
            echo "ERROR: download failed for product runtime asset set under ${AIRPLANES_RUNTIME_DOWNLOAD_BASE}/${tag}" >&2
            return 1
        fi
    fi

    local manifest_name
    manifest_name="$(head -n1 "$(airplanes_runtime_downloaded_manifest_name_file "$dest_dir")")"
    if [[ "$manifest_name" != "manifest.json" ]]; then
        cp -- "$dest_dir/$manifest_name" "$dest_dir/manifest.json"
    fi

    local tarball_name
    tarball_name="$(head -n1 "$(airplanes_runtime_downloaded_tarball_name_file "$dest_dir")")"

    if [[ ! -f "$dest_dir/$tarball_name" || ! -f "$dest_dir/$manifest_name" ]]; then
        echo "ERROR: staged runtime asset set is incomplete in $dest_dir" >&2
        return 1
    fi

    if ! command -v minisign >/dev/null 2>&1; then
        echo "ERROR: required dependency 'minisign' not found on PATH" >&2
        return 1
    fi

    if [[ ! -r "$AIRPLANES_RUNTIME_MINISIGN_PUBKEY" ]]; then
        echo "ERROR: minisign public key not readable: $AIRPLANES_RUNTIME_MINISIGN_PUBKEY" >&2
        return 1
    fi

    if ! minisign -V \
            -p "$AIRPLANES_RUNTIME_MINISIGN_PUBKEY" \
            -x "$dest_dir/SHA256SUMS.minisig" \
            -m "$dest_dir/SHA256SUMS" >/dev/null 2>&1; then
        echo "ERROR: minisign signature verification failed for $dest_dir/SHA256SUMS" >&2
        return 1
    fi

    local filtered="$dest_dir/SHA256SUMS.expected"
    {
        grep -E "  ${tarball_name}\$" "$dest_dir/SHA256SUMS" || true
        grep -E "  ${manifest_name}\$" "$dest_dir/SHA256SUMS" || true
    } > "$filtered"
    local expected_lines
    expected_lines="$(wc -l < "$filtered")"
    if [[ "$expected_lines" -ne 2 ]]; then
        echo "ERROR: SHA256SUMS missing one of $tarball_name / $manifest_name" >&2
        cat "$dest_dir/SHA256SUMS" >&2
        return 1
    fi

    if ! ( cd "$dest_dir" && sha256sum -c SHA256SUMS.expected >/dev/null ); then
        echo "ERROR: SHA256 verification failed in $dest_dir" >&2
        return 1
    fi
}

airplanes_runtime_verify_manifest_version() {
    local manifest="$1" expected_tag="$2"
    # The release tag is `vX.Y.Z`, `dev-latest`, or `local-assets`; the
    # manifest's `version` is `X.Y.Z` or `X.Y.Z-dev-YYYYMMDD-<sha>`.
    local expected_version="${expected_tag#v}"             # strip "v" if stable
    local got
    got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$manifest" 2>/dev/null || true)"
    if [[ -z "$got" ]]; then
        echo "ERROR: manifest.json missing version field (path: $manifest)" >&2
        return 1
    fi
    if [[ "$expected_tag" == "local-assets" ]]; then
        return 0
    fi
    # The floating dev product release has no version in its tag name; accept
    # any dev-formatted manifest version.
    if [[ "$expected_tag" == "dev-latest" ]]; then
        if [[ ! "$got" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev-[0-9]{8}-[0-9a-f]{7,40}$ ]]; then
            echo "ERROR: manifest.json version=$got is not a dev-formatted version for floating tag $expected_tag" >&2
            return 1
        fi
        return 0
    fi
    if [[ "$got" != "$expected_version" ]]; then
        echo "ERROR: manifest.json version=$got does not match resolved tag=$expected_tag (expected version $expected_version)" >&2
        echo "       A release tag may have moved between resolution and download." >&2
        return 1
    fi
}

# Build-mode only: assert the manifest's commit_sha matches the cloned source
# HEAD. Mirrors image-webconfig's same-named function. Caller passes the
# pre-computed sha so this function doesn't need to know where the source
# tree lives.
airplanes_runtime_verify_manifest_sha() {
    local manifest="$1" expected_sha="$2"
    local got
    got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit_sha",""))' "$manifest" 2>/dev/null || true)"
    if [[ -z "$got" ]]; then
        echo "ERROR: manifest.json missing commit_sha field (path: $manifest)" >&2
        return 1
    fi
    if [[ "$got" != "$expected_sha" ]]; then
        echo "ERROR: manifest.json commit_sha=$got does not match expected=$expected_sha" >&2
        echo "       The release was built from a different source than the cloned repo." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Release tree extraction
# ---------------------------------------------------------------------------
#
# The release tarball expands to a tree of bin/, lib/, share/, systemd/,
# etc/, migrations/ … and a manifest.json at the top. The tar's leading
# directory is `v<version>/` (build-release.sh's contract). We extract
# with `--strip-components=1` so the staging target receives the inner
# tree directly; the caller passes the absolute on-device release dir
# (`/opt/airplanes-runtime/releases/v<version>/`) so the resulting layout
# is the same as a hand-laid release.

airplanes_runtime_extract_release_tarball() {
    local tarball="$1" target_dir="$2"
    install -d -m 755 "$target_dir"
    if ! tar -xzf "$tarball" -C "$target_dir" --strip-components=1; then
        echo "ERROR: release tarball extraction failed: $tarball" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Managed paths (symlink + copy modes)
# ---------------------------------------------------------------------------
#
# Each manifest entry is one of:
#   { mode: symlink, link: <abs>, target: <abs under /opt/airplanes-runtime/current/...> }
#   { mode: copy,    path: <abs>, from: <rel-under-release-dir>, owner: u:g, perm: 0XXX,
#                    post_install: [argv] }
#
# Symlink targets are required absolute by the schema (decision 2). We
# rebase the *link* through TARGET_ROOT for build mode / tests; the symlink
# target is left literal because /opt/airplanes-runtime/current resolves
# inside the final image, not inside the staging tmpdir.

airplanes_runtime_apply_managed_paths() {
    local manifest="$1"
    local release_dir="$2"
    local target_root="$3"

    if [[ ! -f "$manifest" ]]; then
        echo "ERROR: managed-paths: manifest not found: $manifest" >&2
        return 1
    fi

    local count
    count="$(jq -r '.managed_paths | length' "$manifest")"
    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    local i
    for (( i = 0; i < count; i++ )); do
        local mode
        mode="$(jq -r ".managed_paths[$i].mode" "$manifest")"
        case "$mode" in
            symlink)
                _airplanes_runtime_apply_managed_symlink "$manifest" "$i" "$target_root" || return 1
                ;;
            copy)
                _airplanes_runtime_apply_managed_copy "$manifest" "$i" "$release_dir" "$target_root" || return 1
                ;;
            *)
                echo "ERROR: managed_paths[$i].mode unknown: $mode" >&2
                return 1
                ;;
        esac
    done
}

_airplanes_runtime_apply_managed_symlink() {
    local manifest="$1" idx="$2" target_root="$3"
    local link target abs_link
    link="$(jq -r ".managed_paths[$idx].link"   "$manifest")"
    target="$(jq -r ".managed_paths[$idx].target" "$manifest")"

    if [[ "$target" != /* ]]; then
        echo "ERROR: managed_paths[$idx].target must be absolute (got: $target)" >&2
        return 1
    fi
    if [[ "$link" != /* ]]; then
        echo "ERROR: managed_paths[$idx].link must be absolute (got: $link)" >&2
        return 1
    fi

    abs_link="${target_root}${link}"
    install -d -m 755 "$(dirname "$abs_link")"

    # If the link path is a real directory (not a symlink), mv -Tf below would
    # refuse to overwrite it ("cannot overwrite directory with non-directory").
    # Clear it so the rename can land. Its contents were snapshotted by
    # backup_all_symlink_paths earlier in the forward walk (update path); in
    # build mode there is no rollback and the overlay is the intended owner of
    # the path. Guarded so a malformed manifest can't wipe a system tree.
    if [[ -d "$abs_link" && ! -L "$abs_link" ]]; then
        # Guard the RAW manifest link, not the target-root-rebased path: in
        # build mode `${ROOTFS_DIR}/usr` would slip a critical root past an
        # exact-match check, but the raw `/usr` is caught.
        _airplanes_runtime_assert_safe_managed_path "$link" || return 1
        rm -rf -- "$abs_link"
    fi

    # Atomic flip via tmp+rename. `ln -snf` is NOT atomic: it unlinks then
    # creates, leaving a window where the path is missing. mv -Tf with a
    # tmp symlink replaces atomically in a single rename() syscall.
    local tmp="${abs_link}.tmp.$$"
    rm -f -- "$tmp"
    ln -s -- "$target" "$tmp"
    mv -Tf -- "$tmp" "$abs_link"
}

_airplanes_runtime_apply_managed_copy() {
    local manifest="$1" idx="$2" release_dir="$3" target_root="$4"
    local path from owner perm src abs_dst tmp
    path="$(jq -r  ".managed_paths[$idx].path"  "$manifest")"
    from="$(jq -r  ".managed_paths[$idx].from"  "$manifest")"
    owner="$(jq -r ".managed_paths[$idx].owner" "$manifest")"
    perm="$(jq -r  ".managed_paths[$idx].perm"  "$manifest")"

    src="${release_dir}/${from}"
    if [[ ! -f "$src" ]]; then
        echo "ERROR: managed_paths[$idx]: source missing in release dir: $src" >&2
        return 1
    fi
    abs_dst="${target_root}${path}"
    install -d -m 755 "$(dirname "$abs_dst")"

    tmp="${abs_dst}.tmp.$$"
    rm -f -- "$tmp"
    install -m "$perm" "$src" "$tmp"

    # chown only when running as root. Tests run as a normal user against a
    # tmpdir target and would otherwise hard-fail on every copy-mode entry.
    if [[ "$(id -u)" -eq 0 ]]; then
        chown "$owner" "$tmp"
    fi

    # Validate BEFORE the file goes live — run post_install against the
    # STAGED tmp file, not the destination. Each argv element equal to the
    # declared `path` is rewritten to the tmp path, so a validator like
    #   ["/usr/sbin/visudo", "-cf", "/etc/sudoers.d/010_airplanes-webconfig"]
    # checks the staged content. On failure the tmp file is removed and the
    # destination is never touched: an invalid sudoers file never goes live,
    # and a pre-existing destination is left intact (the mv never runs). The
    # path rewrite also makes validation target-root-correct in build mode,
    # where `path` (host-absolute) differs from the staged tmp under the
    # chroot. post_install runs as a single sequential pipeline; abort on the
    # first non-zero.
    local pi_count
    pi_count="$(jq -r ".managed_paths[$idx].post_install | length // 0" "$manifest")"
    if [[ "$pi_count" -gt 0 ]]; then
        local argv_json
        argv_json="$(jq -c ".managed_paths[$idx].post_install" "$manifest")"
        local -a argv=()
        local line
        while IFS= read -r line; do
            if [[ "$line" == "$path" ]]; then
                argv+=("$tmp")
            else
                argv+=("$line")
            fi
        done < <(jq -r '.[]' <<< "$argv_json")
        if ! "${argv[@]}"; then
            echo "ERROR: managed_paths[$idx] post_install failed: ${argv[*]}" >&2
            rm -f -- "$tmp"
            return 1
        fi
    fi

    mv -Tf -- "$tmp" "$abs_dst"
}

# ---------------------------------------------------------------------------
# Managed-path symlink cleanup (rollback + success)
# ---------------------------------------------------------------------------
#
# When the managed_paths set changes between releases, stale symlinks must be
# cleaned up so the FHS surface reflects exactly the active release:
#   - on SUCCESS: remove RETIRED links (present in the prior manifest, absent
#     from the new one) so an old release's path doesn't dangle.
#   - on ROLLBACK: remove NEW-ONLY links (present in the new manifest, absent
#     from the prior one) so a failed install's path doesn't dangle after the
#     `current` flip reverts.
# Only symlink-mode entries are considered; copy-mode targets are handled by
# the copy-preimage restore path. Only links that are actually symlinks are
# removed — never a regular file or directory, so an operator-created file at
# the same path is left alone.

# Emit the absolute `link` of every symlink-mode managed_paths entry in a
# manifest, one per line. Missing manifest / no entries → empty.
_airplanes_runtime_symlink_links() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 0
    jq -r '.managed_paths[]? | select(.mode == "symlink") | .link' "$manifest" 2>/dev/null
}

# Remove the symlinks that are in <set_a manifest> but NOT in <set_b manifest>,
# rebased under target_root. Used both directions: success passes
# (prior, new); rollback passes (new, prior).
_airplanes_runtime_remove_symlinks_only_in() {
    local manifest_a="$1" manifest_b="$2" target_root="$3"
    local b_links
    b_links=" $(_airplanes_runtime_symlink_links "$manifest_b" | tr '\n' ' ') "
    local link
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        [[ "$link" == /* ]] || continue
        # Skip links also present in set B.
        if [[ "$b_links" == *" $link "* ]]; then
            continue
        fi
        local abs="${target_root}${link}"
        # Only remove an actual symlink — never clobber a real file/dir.
        if [[ -L "$abs" ]]; then
            rm -f -- "$abs"
        fi
    done < <(_airplanes_runtime_symlink_links "$manifest_a")
}

# SUCCESS: remove retired links (in prior, not in new).
airplanes_runtime_remove_retired_symlinks() {
    local prev_manifest="$1" new_manifest="$2" target_root="$3"
    [[ -f "$prev_manifest" ]] || return 0
    _airplanes_runtime_remove_symlinks_only_in "$prev_manifest" "$new_manifest" "$target_root"
}

# ROLLBACK: remove new-only links (in new, not in prior).
airplanes_runtime_remove_new_only_symlinks() {
    local new_manifest="$1" prev_manifest="$2" target_root="$3"
    [[ -f "$new_manifest" ]] || return 0
    _airplanes_runtime_remove_symlinks_only_in "$new_manifest" "$prev_manifest" "$target_root"
}

# ---------------------------------------------------------------------------
# systemd ops
# ---------------------------------------------------------------------------
#
# Order: daemon-reload (if requested) → disable retired units → enable new
# units → restart in the helper-hardcoded order. Restart order is hardcoded
# (decision 5) because it encodes cross-service producer/consumer ordering
# (readsb → dump978 → airplanes-978 → uat-sync) that the manifest schema
# deliberately does not expose.

# Hardcoded restart order. Add new units here when their startup ordering
# matters; everything not listed is a no-op for restart (still enabled).
# tar1090/graphs1090 restart LAST, after the decode chain they read from. They
# must be restarted on update (not just enabled) so the new release's unit
# files actually start under the self-update health gate — otherwise the gate
# would validate the prior release's still-running process.
_airplanes_runtime_restart_order=(
    "readsb.service"
    "dump978-fa.service"
    "airplanes-978.service"
    "airplanes-tar1090-uat-sync.service"
    "tar1090.service"
    "graphs1090.service"
    "airplanes-feed.service"
    "airplanes-mlat.service"
    "airplanes-webconfig.service"
)

airplanes_runtime_apply_systemd_ops() {
    local manifest="$1"

    if airplanes_runtime_is_build_mode; then
        # Build mode runs in pi-gen's chroot via the policy-rc.d/systemctl
        # shim; restarts happen on first boot. Only the unit-state edits
        # matter at build time and those are delegated to the chroot stage
        # that consumes this function — at the helper layer we no-op.
        return 0
    fi

    if [[ ! -f "$manifest" ]]; then
        echo "ERROR: systemd: manifest not found: $manifest" >&2
        return 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        echo "ERROR: systemctl not found on PATH" >&2
        return 1
    fi

    local daemon_reload
    daemon_reload="$(jq -r '.systemd.daemon_reload' "$manifest")"
    if [[ "$daemon_reload" == "true" ]]; then
        systemctl daemon-reload
    fi

    local unit
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        systemctl disable --now "$unit" || true
    done < <(jq -r '.systemd.disable[]?' "$manifest")

    local -a enable_units=()
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        enable_units+=("$unit")
    done < <(jq -r '.systemd.enable[]?' "$manifest")
    if (( ${#enable_units[@]} > 0 )); then
        systemctl enable "${enable_units[@]}"
    fi

    # Restart pass: walk the hardcoded order and restart only those units
    # that the manifest declared in `enable` (so disabled-on-this-host units
    # don't get started by surprise).
    local enabled_list
    enabled_list=" $(jq -r '.systemd.enable[]?' "$manifest" | tr '\n' ' ') "
    local u
    for u in "${_airplanes_runtime_restart_order[@]}"; do
        if [[ "$enabled_list" == *" $u "* ]]; then
            systemctl restart "$u" || return 1
        fi
    done

    # Reload-or-restart pass: for units carrying overlay-managed config where a
    # full restart is unnecessary (e.g. lighttpd picking up a new conf snippet)
    # the manifest lists them under systemd.reload_or_restart. `reload-or-
    # restart` reloads if the unit declares ExecReload, otherwise restarts.
    local r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        systemctl reload-or-restart "$r" || return 1
    done < <(jq -r '.systemd.reload_or_restart[]?' "$manifest")
}

# Start every *.timer / *.path in the manifest's enable list. `systemctl
# enable` writes the relevant target's wants-link but does not arm a
# timer or path-watcher in the current boot — on a fresh flash that's
# fine (timers.target / paths.target brings them up at boot) but on an
# in-place runtime self-update or a direct install.sh --runtime invocation
# the newly-enabled activator would otherwise stay idle until reboot.
#
# Best-effort by design: callers run this AFTER the health gate has
# already validated the release, so a failure here is a regression in
# something the release is not on the hook for — log and continue. Any
# *.service entries in enable[] are skipped: long-running daemons are
# already covered by apply_systemd_ops' restart pass, and oneshots that
# only ever run via a timer's Unit= directive must not be force-started.
#
# Idempotent: `systemctl start` on an already-active activator is a
# no-op. Caveat: a timer past its OnBootSec= (or Persistent=true catching
# up a missed run) fires its unit on start — by design, so the first
# tick lands at finalize time instead of waiting another cycle.
airplanes_runtime_start_enabled_activators() {
    local manifest="$1"

    if airplanes_runtime_is_build_mode; then
        # Build mode runs in pi-gen's chroot via the policy-rc.d/systemctl
        # shim; activators get started by timers.target / paths.target on
        # first boot — same posture as apply_systemd_ops' restart pass.
        return 0
    fi

    if [[ ! -f "$manifest" ]]; then
        echo "ERROR: start_activators: manifest not found: $manifest" >&2
        return 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        echo "ERROR: start_activators: systemctl not found on PATH" >&2
        return 1
    fi

    local unit
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        case "$unit" in
            *.timer|*.path)
                systemctl start "$unit" \
                    || echo "WARN: start_activators: $unit: start failed" >&2
                ;;
        esac
    done < <(jq -r '.systemd.enable[]?' "$manifest")
}

# ---------------------------------------------------------------------------
# Mutable-path preimage backup + restore
# ---------------------------------------------------------------------------
#
# `mutable_paths[]` declares FHS files the runtime overlay creates but does
# not overwrite. Operator-edited config (/etc/default/tar1090,
# /etc/collectd/collectd.conf) lives here. Before any migration mutates
# such a file, we copy the live content to <release-dir>/.mutable-preimage/
# so the rollback path can restore it. The preimage is per-release-dir so
# it survives a helper restart between the migration phase and the rollback
# phase (the file lives next to the release tree, not in /tmp).

# Encode an absolute path into a single filename by replacing '/' with '__'.
# The leading '/' becomes a leading '__' which is fine — file names just
# need to be unambiguous, not pretty.
_airplanes_runtime_encode_path() {
    local p="$1"
    printf '%s' "${p//\//__}"
}

# Refuse to rm -rf a path that is empty, relative, or a critical FHS root /
# top-level system directory. Restore and the dir→symlink clobber in
# apply_managed_symlink both delete the live path before replacing it; a
# malformed or hostile manifest declaring `/` or `/usr` as a managed
# destination must fail the operation, never recursively wipe a system tree.
_airplanes_runtime_assert_safe_managed_path() {
    local p="$1"
    if [[ -z "$p" || "$p" != /* ]]; then
        echo "ERROR: refusing unsafe managed path (empty or relative): '$p'" >&2
        return 1
    fi
    local norm="$p"
    [[ "$norm" != "/" ]] && norm="${norm%/}"
    case "$norm" in
        ""|"/"|/usr|/etc|/var|/bin|/sbin|/lib|/lib64|/boot|/opt|/home|/root|/run|/proc|/sys|/dev|/opt/airplanes-runtime|/opt/airplanes-runtime/*)
            echo "ERROR: refusing to operate on critical system path: '$p'" >&2
            return 1
            ;;
    esac
    return 0
}

# Generic per-path preimage backup/restore. The mutable, copy, and symlink
# families below are thin wrappers over these two — they differ only in the
# preimage directory and the manifest section they walk. The primitive handles
# regular files, directories, and symlinks (including dangling ones — `cp -a`
# preserves a symlink as a symlink), recording an <enc>.absent sentinel when
# nothing is at the path. Backup is write-once (never clobber a captured
# original with an already-mutated intermediate) and crash-safe: the snapshot
# is staged to a temp name and atomically renamed, so an interrupted or
# out-of-space copy never leaves a partial tree that write-once would later
# trust as the original.
_airplanes_runtime_preimage_backup() {
    local preimage_dir="$1" target_root="$2" abs_path="$3"
    install -d -m 700 "$preimage_dir" || return 1
    local enc
    enc="$(_airplanes_runtime_encode_path "$abs_path")"
    if [[ -e "${preimage_dir}/${enc}" || -e "${preimage_dir}/${enc}.absent" ]]; then
        return 0
    fi
    local src="${target_root}${abs_path}"
    local tmp="${preimage_dir}/${enc}.tmp.$$"
    rm -rf -- "$tmp"
    # Check every step: these functions are called from `if !` / `|| return`
    # contexts, which disables `errexit` inside them, so a failed cp must not
    # let the partial tmp tree get promoted to the write-once preimage.
    if [[ -e "$src" || -L "$src" ]]; then
        cp -a -- "$src" "$tmp"                       || { rm -rf -- "$tmp"; return 1; }
        mv -Tf -- "$tmp" "${preimage_dir}/${enc}"    || { rm -rf -- "$tmp"; return 1; }
    else
        : > "$tmp"                                   || { rm -rf -- "$tmp"; return 1; }
        mv -Tf -- "$tmp" "${preimage_dir}/${enc}.absent" || { rm -rf -- "$tmp"; return 1; }
    fi
}

_airplanes_runtime_preimage_restore() {
    local preimage_dir="$1" target_root="$2" abs_path="$3"
    local enc
    enc="$(_airplanes_runtime_encode_path "$abs_path")"
    local dst="${target_root}${abs_path}"
    if [[ -f "${preimage_dir}/${enc}.absent" ]]; then
        # Path did not exist before this install → remove what the failed
        # release left. rm -f (not -rf): the only expected artifact is a file
        # or symlink, never a populated directory.
        rm -f -- "$dst"
        return 0
    fi
    if [[ -e "${preimage_dir}/${enc}" || -L "${preimage_dir}/${enc}" ]]; then
        # Clear the live path first so a directory preimage doesn't nest under
        # an existing directory of the same name; the preimage is the
        # authoritative copy. Guard the RAW manifest path (target-root-
        # independent) so a build-mode rebase can't slip a critical root past
        # the check.
        _airplanes_runtime_assert_safe_managed_path "$abs_path" || return 1
        rm -rf -- "$dst"
        install -d -m 755 "$(dirname "$dst")" || return 1
        cp -a -- "${preimage_dir}/${enc}" "$dst" || return 1
        return 0
    fi
    # No preimage and no absent-marker → nothing was backed up. Treat as
    # no-op rather than failing the whole rollback.
    return 0
}

airplanes_runtime_backup_mutable_path() {
    local release_dir="$1" target_root="$2" abs_path="$3"
    _airplanes_runtime_preimage_backup "${release_dir}/.mutable-preimage" "$target_root" "$abs_path"
}

airplanes_runtime_restore_mutable_path() {
    local release_dir="$1" target_root="$2" abs_path="$3"
    _airplanes_runtime_preimage_restore "${release_dir}/.mutable-preimage" "$target_root" "$abs_path"
}

# Walk all mutable_paths in the manifest and back each up. Convenience
# wrapper for the orchestration step before migrations.
airplanes_runtime_backup_all_mutable_paths() {
    local manifest="$1" release_dir="$2" target_root="$3"
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        airplanes_runtime_backup_mutable_path "$release_dir" "$target_root" "$p" || return 1
    done < <(jq -r '.mutable_paths[]?' "$manifest")
}

airplanes_runtime_restore_all_mutable_paths() {
    local manifest="$1" release_dir="$2" target_root="$3"
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        airplanes_runtime_restore_mutable_path "$release_dir" "$target_root" "$p" || return 1
    done < <(jq -r '.mutable_paths[]?' "$manifest")
}

# ---------------------------------------------------------------------------
# Copy-mode managed-path preimage backup + restore
# ---------------------------------------------------------------------------
#
# Copy-mode entries write directly to an FHS location, so a rollback would
# otherwise leave the failed release's file in place. Before the copy write,
# snapshot the live target into <release-dir>/.copy-preimage/ so the rollback
# path can restore it (or delete it, if the release created it). Same shape
# as the mutable-path preimage above, but keyed off the
# managed_paths[].mode == "copy" entries and a separate preimage dir so the
# families never collide.

airplanes_runtime_backup_copy_path() {
    local release_dir="$1" target_root="$2" abs_path="$3"
    _airplanes_runtime_preimage_backup "${release_dir}/.copy-preimage" "$target_root" "$abs_path"
}

airplanes_runtime_restore_copy_path() {
    local release_dir="$1" target_root="$2" abs_path="$3"
    _airplanes_runtime_preimage_restore "${release_dir}/.copy-preimage" "$target_root" "$abs_path"
}

# Walk all copy-mode managed_paths and back each target up before the copy
# write. Convenience wrapper for the orchestration step alongside the mutable
# backup.
airplanes_runtime_backup_all_copy_paths() {
    local manifest="$1" release_dir="$2" target_root="$3"
    local count i mode path
    count="$(jq -r '(.managed_paths // []) | length' "$manifest")"
    for (( i = 0; i < count; i++ )); do
        mode="$(jq -r ".managed_paths[$i].mode" "$manifest")"
        [[ "$mode" == "copy" ]] || continue
        path="$(jq -r ".managed_paths[$i].path" "$manifest")"
        airplanes_runtime_backup_copy_path "$release_dir" "$target_root" "$path" || return 1
    done
}

airplanes_runtime_restore_all_copy_paths() {
    local manifest="$1" release_dir="$2" target_root="$3"
    local count i mode path
    count="$(jq -r '(.managed_paths // []) | length' "$manifest")"
    for (( i = 0; i < count; i++ )); do
        mode="$(jq -r ".managed_paths[$i].mode" "$manifest")"
        [[ "$mode" == "copy" ]] || continue
        path="$(jq -r ".managed_paths[$i].path" "$manifest")"
        airplanes_runtime_restore_copy_path "$release_dir" "$target_root" "$path" || return 1
    done
}

# ---------------------------------------------------------------------------
# Symlink-mode managed-path preimage backup + restore
# ---------------------------------------------------------------------------
#
# A symlink-mode entry whose link path already holds non-symlink content — a
# real directory or file from an OS package or an externally-modified path, or
# even a pre-existing OS/operator symlink — would otherwise be lost on rollback:
# `remove_new_only_symlinks` + the `current` flip only recover overlay-managed
# symlinks, and the dir→symlink case can't even be applied (mv -Tf refuses to
# overwrite a directory). Snapshot whatever is at each link into
# <release-dir>/.symlink-preimage/ before apply so rollback can put it back —
# including the case where the same link's target changed between releases.
#
# Note: this is a build-time-only concern on real devices. The flashed image
# already ships these paths as symlinks (stage-02 lays the overlay in build
# mode), so on-device updates are symlink→symlink and the heavy dir→symlink
# branch never runs there. The boot-time recover-shim — the base-OS recovery
# floor — deliberately only flips `current` and does NOT restore preimages, so
# a power loss mid dir→symlink replacement is an accepted (build-time-only)
# limitation rather than a fielded risk.
airplanes_runtime_backup_symlink_path() {
    local release_dir="$1" target_root="$2" abs_path="$3"
    _airplanes_runtime_preimage_backup "${release_dir}/.symlink-preimage" "$target_root" "$abs_path"
}

airplanes_runtime_restore_symlink_path() {
    local release_dir="$1" target_root="$2" abs_path="$3"
    _airplanes_runtime_preimage_restore "${release_dir}/.symlink-preimage" "$target_root" "$abs_path"
}

airplanes_runtime_backup_all_symlink_paths() {
    local manifest="$1" release_dir="$2" target_root="$3"
    local count i mode link
    count="$(jq -r '(.managed_paths // []) | length' "$manifest")"
    for (( i = 0; i < count; i++ )); do
        mode="$(jq -r ".managed_paths[$i].mode" "$manifest")"
        [[ "$mode" == "symlink" ]] || continue
        link="$(jq -r ".managed_paths[$i].link" "$manifest")"
        airplanes_runtime_backup_symlink_path "$release_dir" "$target_root" "$link" || return 1
    done
}

airplanes_runtime_restore_all_symlink_paths() {
    local manifest="$1" release_dir="$2" target_root="$3"
    local count i mode link
    count="$(jq -r '(.managed_paths // []) | length' "$manifest")"
    for (( i = 0; i < count; i++ )); do
        mode="$(jq -r ".managed_paths[$i].mode" "$manifest")"
        [[ "$mode" == "symlink" ]] || continue
        link="$(jq -r ".managed_paths[$i].link" "$manifest")"
        airplanes_runtime_restore_symlink_path "$release_dir" "$target_root" "$link" || return 1
    done
}

# ---------------------------------------------------------------------------
# Migrations
# ---------------------------------------------------------------------------
#
# Schema declares four behavioural migration types plus three "reload"
# stubs. Forward runner walks them in declared order; rollback runner walks
# them in REVERSE order, only touching those that completed forward.
# Completion is recorded by appending the migration id to
# /etc/airplanes/runtime-migrations.applied so cross-install state survives
# helper restarts.

_airplanes_runtime_applied_file_path() {
    local target_root="$1"
    printf '%s' "${target_root}/${AIRPLANES_RUNTIME_MIGRATIONS_APPLIED_REL}"
}

# Per-install-attempt completed list. Lives inside the new release dir so
# it survives a helper restart but is scoped to this install attempt — a
# rollback walks only this list, never the cross-install
# /etc/airplanes/runtime-migrations.applied file (which records "ever
# applied", not "applied in this attempt").
_airplanes_runtime_attempt_file_path() {
    local release_dir="$1"
    printf '%s' "${release_dir}/.attempt-migrations.applied"
}

_airplanes_runtime_migration_recorded() {
    local target_root="$1" mid="$2"
    local f
    f="$(_airplanes_runtime_applied_file_path "$target_root")"
    [[ -f "$f" ]] || return 1
    grep -Fxq "$mid" "$f"
}

_airplanes_runtime_migration_attempted() {
    local release_dir="$1" mid="$2"
    local f
    f="$(_airplanes_runtime_attempt_file_path "$release_dir")"
    [[ -f "$f" ]] || return 1
    grep -Fxq "$mid" "$f"
}

_airplanes_runtime_migration_record() {
    local target_root="$1" release_dir="$2" mid="$3"
    local f
    f="$(_airplanes_runtime_applied_file_path "$target_root")"
    install -d -m 755 "$(dirname "$f")"
    if ! _airplanes_runtime_migration_recorded "$target_root" "$mid"; then
        printf '%s\n' "$mid" >> "$f"
    fi
    # Also record into the per-attempt file so rollback can walk just
    # this attempt's completions.
    local af
    af="$(_airplanes_runtime_attempt_file_path "$release_dir")"
    install -d -m 755 "$(dirname "$af")"
    if ! _airplanes_runtime_migration_attempted "$release_dir" "$mid"; then
        printf '%s\n' "$mid" >> "$af"
    fi
}

_airplanes_runtime_migration_unrecord() {
    local target_root="$1" release_dir="$2" mid="$3"
    local f tmp
    f="$(_airplanes_runtime_applied_file_path "$target_root")"
    if [[ -f "$f" ]]; then
        tmp="${f}.tmp.$$"
        if ! grep -Fxv "$mid" "$f" > "$tmp"; then
            # grep returns 1 when nothing matched after inversion, i.e.
            # the input was empty or every line was "$mid". Empty output
            # is fine.
            :
        fi
        mv -Tf -- "$tmp" "$f"
    fi
    # Also strip from the per-attempt file so a re-run of rollback doesn't
    # double-roll-back the same migration.
    local af
    af="$(_airplanes_runtime_attempt_file_path "$release_dir")"
    if [[ -f "$af" ]]; then
        tmp="${af}.tmp.$$"
        if ! grep -Fxv "$mid" "$af" > "$tmp"; then
            :
        fi
        mv -Tf -- "$tmp" "$af"
    fi
}

# Apply a single migration forward. Returns 0 on success, non-zero on
# failure (which the caller propagates so the orchestrator can flip to
# rollback). Returns 0 silently if `run_when:first_install_of_version` and
# the migration id is already recorded.
_airplanes_runtime_migration_apply_forward() {
    local manifest="$1" idx="$2" release_dir="$3" target_root="$4"
    local mid mtype run_when
    mid="$(jq -r       ".migrations[$idx].id"       "$manifest")"
    mtype="$(jq -r     ".migrations[$idx].type"     "$manifest")"
    run_when="$(jq -r  ".migrations[$idx].run_when // \"every_install\"" "$manifest")"

    if [[ "$run_when" == "first_install_of_version" ]] \
            && _airplanes_runtime_migration_recorded "$target_root" "$mid"; then
        return 0
    fi

    case "$mtype" in
        group_membership)
            _airplanes_runtime_apply_group_membership "$manifest" "$idx" || return 1
            ;;
        config_kv)
            _airplanes_runtime_apply_config_kv "$manifest" "$idx" "$release_dir" "$target_root" || return 1
            ;;
        shell)
            _airplanes_runtime_apply_shell_forward "$manifest" "$idx" "$release_dir" "$target_root" || return 1
            ;;
        udev_reload)
            if command -v udevadm >/dev/null 2>&1; then
                udevadm control --reload-rules || true
            fi
            ;;
        sysctl_reload)
            if command -v sysctl >/dev/null 2>&1; then
                sysctl --system >/dev/null || true
            fi
            ;;
        nmcli_reload)
            if command -v nmcli >/dev/null 2>&1; then
                nmcli connection reload || true
            fi
            ;;
        *)
            echo "ERROR: migrations[$idx].type unknown: $mtype" >&2
            return 1
            ;;
    esac

    _airplanes_runtime_migration_record "$target_root" "$release_dir" "$mid"
}

airplanes_runtime_run_migrations_forward() {
    local manifest="$1" release_dir="$2" target_root="$3"
    local count
    count="$(jq -r '.migrations | length' "$manifest")"
    local i
    for (( i = 0; i < count; i++ )); do
        if ! _airplanes_runtime_migration_apply_forward "$manifest" "$i" "$release_dir" "$target_root"; then
            return 1
        fi
    done
}

# Apply a single migration's rollback. Only invoked for migrations that
# completed forward in this install. The orchestrator is responsible for
# tracking which migrations completed before failure — at the function
# layer we trust the caller.
_airplanes_runtime_migration_apply_rollback() {
    local manifest="$1" idx="$2" release_dir="$3" target_root="$4"
    local mid mtype
    mid="$(jq -r   ".migrations[$idx].id"   "$manifest")"
    mtype="$(jq -r ".migrations[$idx].type" "$manifest")"

    case "$mtype" in
        group_membership)
            # Group membership is idempotent and conservative — we do not
            # remove the user from the group on rollback. Removing readsb
            # from plugdev/dialout could brick SDR access if the prior
            # release relied on the same membership.
            ;;
        config_kv)
            # config_kv mutations were preimaged before the forward step
            # via the mutable_paths backup path. Restore from preimage.
            local file
            file="$(jq -r ".migrations[$idx].file" "$manifest")"
            airplanes_runtime_restore_mutable_path "$release_dir" "$target_root" "$file" || return 1
            ;;
        shell)
            _airplanes_runtime_apply_shell_rollback "$manifest" "$idx" "$release_dir" "$target_root" || return 1
            ;;
        udev_reload|sysctl_reload|nmcli_reload)
            # Re-running the same reload is idempotent. We re-fire so the
            # post-rollback system reflects the prior release's rules.
            case "$mtype" in
                udev_reload)
                    if command -v udevadm >/dev/null 2>&1; then
                        udevadm control --reload-rules || true
                    fi
                    ;;
                sysctl_reload)
                    if command -v sysctl >/dev/null 2>&1; then
                        sysctl --system >/dev/null || true
                    fi
                    ;;
                nmcli_reload)
                    if command -v nmcli >/dev/null 2>&1; then
                        nmcli connection reload || true
                    fi
                    ;;
            esac
            ;;
        *)
            echo "ERROR: rollback: migrations[$idx].type unknown: $mtype" >&2
            return 1
            ;;
    esac

    _airplanes_runtime_migration_unrecord "$target_root" "$release_dir" "$mid"
}

# Rollback walks the per-install-attempt completed list, not the
# cross-install applied file. That distinction matters because some
# migrations are `first_install_of_version` and were recorded as
# "ever applied" on a previous successful install; we must NOT roll those
# back when a later install attempt fails — that would undo work the
# system depends on.
airplanes_runtime_run_migrations_rollback() {
    local manifest="$1" release_dir="$2" target_root="$3"
    local count
    count="$(jq -r '.migrations | length' "$manifest")"
    local i
    for (( i = count - 1; i >= 0; i-- )); do
        local mid
        mid="$(jq -r ".migrations[$i].id" "$manifest")"
        if _airplanes_runtime_migration_attempted "$release_dir" "$mid"; then
            _airplanes_runtime_migration_apply_rollback "$manifest" "$i" "$release_dir" "$target_root" || return 1
        fi
    done
}

_airplanes_runtime_apply_group_membership() {
    local manifest="$1" idx="$2"
    local user
    user="$(jq -r ".migrations[$idx].user" "$manifest")"
    if [[ -z "$user" || "$user" == "null" ]]; then
        echo "ERROR: migrations[$idx]: group_membership missing user" >&2
        return 1
    fi
    local g
    while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        # getent's exit code is non-zero when the group doesn't exist; treat
        # that as fatal so a typo'd group name surfaces instead of silently
        # no-op'ing. The idempotent check uses fixed-string match on the
        # comma-separated member list to avoid false positives on
        # substring-match users (e.g. "readsbx" matching "readsb").
        if ! getent group "$g" >/dev/null 2>&1; then
            echo "ERROR: migrations[$idx]: group does not exist: $g" >&2
            return 1
        fi
        local current_members
        current_members="$(getent group "$g" | awk -F: '{print $4}')"
        local already=0
        local m
        for m in ${current_members//,/ }; do
            if [[ "$m" == "$user" ]]; then
                already=1
                break
            fi
        done
        if (( already == 0 )); then
            if ! adduser "$user" "$g" >/dev/null 2>&1; then
                echo "ERROR: migrations[$idx]: adduser $user $g failed" >&2
                return 1
            fi
        fi
    done < <(jq -r ".migrations[$idx].groups[]" "$manifest")
}

_airplanes_runtime_apply_config_kv() {
    local manifest="$1" idx="$2" release_dir="$3" target_root="$4"
    local file if_key_unset
    file="$(jq -r          ".migrations[$idx].file"         "$manifest")"
    if_key_unset="$(jq -r  ".migrations[$idx].if_key_unset // false" "$manifest")"

    local abs_file="${target_root}${file}"
    install -d -m 755 "$(dirname "$abs_file")"
    # Preimage backup so rollback can restore the original contents.
    airplanes_runtime_backup_mutable_path "$release_dir" "$target_root" "$file" || return 1

    if [[ ! -f "$abs_file" ]]; then
        : > "$abs_file"
    fi

    # Walk the set object key by key. Each value is a string per schema.
    local kv_json
    kv_json="$(jq -c ".migrations[$idx].set" "$manifest")"
    local keys
    keys="$(jq -r 'keys[]' <<< "$kv_json")"
    local k v
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        v="$(jq -r --arg k "$k" '.[$k]' <<< "$kv_json")"
        if [[ "$if_key_unset" == "true" ]] && grep -qE "^[[:space:]]*${k}=" "$abs_file"; then
            # Key already present — honour the "don't overwrite" promise.
            continue
        fi
        _airplanes_runtime_set_kv "$abs_file" "$k" "$v" || return 1
    done <<< "$keys"
}

# Idempotent KEY=value setter. Updates an existing line in place; appends
# if not present. Quoting/escaping is intentionally minimal — the schema
# accepts arbitrary string values, but the v1 surface (tar1090 defaults,
# collectd snippets) is single-token enums.
_airplanes_runtime_set_kv() {
    local file="$1" key="$2" value="$3"
    local tmp
    tmp="${file}.tmp.$$"
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        sed -E "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$file" > "$tmp"
    else
        cat -- "$file" > "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv -f -- "$tmp" "$file"
}

_airplanes_runtime_apply_shell_forward() {
    local manifest="$1" idx="$2" release_dir="$3" target_root="$4"
    local script
    script="$(jq -r ".migrations[$idx].script" "$manifest")"
    local abs="${release_dir}/${script}"
    if [[ ! -f "$abs" ]]; then
        echo "ERROR: migrations[$idx]: forward script missing: $abs" >&2
        return 1
    fi
    PREV_RELEASE_DIR="${PREV_RELEASE_DIR:-}" \
    RELEASE_DIR="$release_dir" \
    AIRPLANES_RUNTIME_TARGET_ROOT="$target_root" \
        bash "$abs"
}

_airplanes_runtime_apply_shell_rollback() {
    local manifest="$1" idx="$2" release_dir="$3" target_root="$4"
    local script
    script="$(jq -r ".migrations[$idx].rollback_script" "$manifest")"
    local abs="${release_dir}/${script}"
    if [[ ! -f "$abs" ]]; then
        echo "ERROR: migrations[$idx]: rollback script missing: $abs" >&2
        return 1
    fi
    PREV_RELEASE_DIR="${PREV_RELEASE_DIR:-}" \
    RELEASE_DIR="$release_dir" \
    AIRPLANES_RUNTIME_TARGET_ROOT="$target_root" \
        bash "$abs"
}

# ---------------------------------------------------------------------------
# Atomic flip of the `current` symlink
# ---------------------------------------------------------------------------

airplanes_runtime_flip_current() {
    local new_release_dir="$1" target_root="$2"
    if [[ "$new_release_dir" != /* ]]; then
        echo "ERROR: flip_current: new release dir must be absolute (got: $new_release_dir)" >&2
        return 1
    fi
    local current_link="${target_root}/opt/airplanes-runtime/current"
    install -d -m 755 "$(dirname "$current_link")"
    local tmp="${current_link}.tmp.$$"
    rm -f -- "$tmp"
    ln -s -- "$new_release_dir" "$tmp"
    mv -Tf -- "$tmp" "$current_link"
}

# Re-create decoder binary symlinks. Both /usr/bin/readsb and
# /usr/bin/airplanes-978 point at /opt/airplanes-runtime/current/bin/readsb
# (the same binary handles both 1090 and 978 frame consumption when
# invoked under either name; decision 14 — both are symlinks, not
# hardlinks, so the post-flip relink is the canonical refresh).
airplanes_runtime_relink_decoder_binaries() {
    local target_root="$1"
    local current_bin="/opt/airplanes-runtime/current/bin/readsb"
    local link
    for link in "/usr/bin/readsb" "/usr/bin/airplanes-978"; do
        local abs="${target_root}${link}"
        install -d -m 755 "$(dirname "$abs")"
        local tmp="${abs}.tmp.$$"
        rm -f -- "$tmp"
        ln -s -- "$current_bin" "$tmp"
        mv -Tf -- "$tmp" "$abs"
    done
}

# ---------------------------------------------------------------------------
# Health gates
# ---------------------------------------------------------------------------
#
# All gates are short-deadline polls so a failed update can flip to rollback
# without the operator waiting minutes. The HTTP probes target the loopback
# lighttpd reverse proxy on the feeder; the tests override the URL base via
# AIRPLANES_RUNTIME_PROBE_URL_BASE.

# Returns 0 if URL responds 200 within the deadline. Polls every second.
# Uses a wall-clock end timestamp and caps each curl's --max-time to the
# remaining budget so a hanging socket can't extend total runtime far past
# the declared deadline.
_airplanes_runtime_probe_http_200() {
    local url="$1" deadline="$2"
    local end now code remaining curl_timeout
    end=$(( $(date +%s) + deadline ))
    while :; do
        now="$(date +%s)"
        remaining=$(( end - now ))
        if (( remaining <= 0 )); then
            echo "ERROR: HTTP probe never returned 200 within ${deadline}s: $url (last code=${code:-?})" >&2
            return 1
        fi
        # Cap curl's per-call timeout to whatever budget is left, with a
        # ceiling of 5s so a single slow probe can't burn the rest of the
        # deadline.
        curl_timeout=$(( remaining < 5 ? remaining : 5 ))
        (( curl_timeout < 1 )) && curl_timeout=1
        code="$(curl -fso /dev/null -w '%{http_code}' --max-time "$curl_timeout" "$url" || true)"
        if [[ "$code" == "200" ]]; then
            return 0
        fi
        # Sleep up to 1s but never overshoot the deadline.
        now="$(date +%s)"
        remaining=$(( end - now ))
        if (( remaining <= 0 )); then
            echo "ERROR: HTTP probe never returned 200 within ${deadline}s: $url (last code=${code:-?})" >&2
            return 1
        fi
        sleep 1
    done
}

# Returns 0 if the file exists AND its mtime is within `max_age` seconds.
# Wall-clock deadline (matching _airplanes_runtime_probe_http_200).
_airplanes_runtime_probe_file_freshness() {
    local file="$1" max_age="$2" deadline="$3"
    local end now mtime age=0
    end=$(( $(date +%s) + deadline ))
    while :; do
        now="$(date +%s)"
        if (( now >= end )); then
            echo "ERROR: $file did not become fresh within ${deadline}s (age=${age}s, max=${max_age}s)" >&2
            return 1
        fi
        if [[ -f "$file" ]]; then
            mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
            age=$(( now - mtime ))
            if (( age <= max_age )); then
                return 0
            fi
        fi
        sleep 1
    done
}

# Parses a key-value state file (one `key=value` per line) and emits the
# value for the requested key, or empty string if missing/unset. Trims
# surrounding whitespace. The parser is intentionally line-oriented and
# does not interpret comments or continuations — the producers (readsb
# wrappers, dump978-fa wrapper, airplanes-978 wrapper) emit strict
# `key=value\n` lines.
_airplanes_runtime_parse_state_kv() {
    local file="$1" key="$2"
    [[ -r "$file" ]] || { printf ''; return 0; }
    awk -F= -v k="$key" '
        $0 ~ "^[[:space:]]*"k"=" {
            sub("^[[:space:]]*"k"=", "")
            sub("[[:space:]]*$", "")
            print
            exit
        }
    ' "$file"
}

# UAT state gate: state file at /run/<unit>/state, key-value format.
# Valid combinations (decision 4):
#   state=enabled,  reason=               (active)
#   state=disabled, reason=uat_disabled
#   state=enabled,  reason=no_hardware
#   state=enabled,  reason=peer_no_hardware
# Anything else fails.
_airplanes_runtime_probe_uat_state() {
    local file="$1" deadline="$2"
    local end now state="" reason=""
    end=$(( $(date +%s) + deadline ))
    while :; do
        now="$(date +%s)"
        if (( now >= end )); then
            echo "ERROR: UAT state file never reached a valid (state, reason) combination within ${deadline}s: $file (state='${state}' reason='${reason}')" >&2
            return 1
        fi
        if [[ -f "$file" ]]; then
            state="$(_airplanes_runtime_parse_state_kv "$file" state)"
            reason="$(_airplanes_runtime_parse_state_kv "$file" reason)"
            case "${state}|${reason}" in
                "enabled|"|"disabled|uat_disabled"|"enabled|no_hardware"|"enabled|peer_no_hardware")
                    return 0
                    ;;
            esac
        fi
        sleep 1
    done
}

# Webconfig version gate: probe /health through lighttpd and confirm the
# serving binary matches the manifest's webconfig component. /health returns
# plain-text `ok <version>\n`, where <version> is the release tag with a
# `+<short-sha>` build-metadata suffix (the release pipeline always stamps
# commitSha). The manifest records the webconfig component as
# {commit_sha, version}; the short commit SHA (first 7 hex) is the precise
# "this binary was built from the release we just installed" invariant and is
# present in the /health output on every channel. We require the probe to
# return 200 AND the body to carry the expected 7-char short SHA, so a stale
# webconfig process (old binary still serving after a failed swap) is rejected
# even though it would answer 200.
#
# Args: <url> <expected-short-sha> <deadline>
_airplanes_runtime_probe_webconfig_version() {
    local url="$1" expected_short="$2" deadline="$3"
    local end now body code remaining curl_timeout
    end=$(( $(date +%s) + deadline ))
    while :; do
        now="$(date +%s)"
        remaining=$(( end - now ))
        if (( remaining <= 0 )); then
            echo "ERROR: /health never reported expected webconfig version within ${deadline}s: $url (want short-sha=$expected_short, last body='${body:-}')" >&2
            return 1
        fi
        curl_timeout=$(( remaining < 5 ? remaining : 5 ))
        (( curl_timeout < 1 )) && curl_timeout=1
        body="$(curl -fsS -w $'\n%{http_code}' --max-time "$curl_timeout" "$url" 2>/dev/null || true)"
        code="${body##*$'\n'}"
        local payload="${body%$'\n'*}"
        if [[ "$code" == "200" && "$payload" == *"$expected_short"* ]]; then
            return 0
        fi
        now="$(date +%s)"
        remaining=$(( end - now ))
        (( remaining <= 0 )) && {
            echo "ERROR: /health never reported expected webconfig version within ${deadline}s: $url (want short-sha=$expected_short, last code=${code:-?} body='${payload:-}')" >&2
            return 1
        }
        sleep 1
    done
}

# Resolve the webconfig component's expected short commit SHA from the release
# manifest. The component may be a bare SHA string (legacy) or an object with
# a commit_sha field. Echoes the 7-char short SHA, or empty if no webconfig
# component is declared (a decoder-only release — the gate then no-ops).
_airplanes_runtime_manifest_webconfig_short_sha() {
    local manifest="$1"
    [[ -f "$manifest" ]] || { printf ''; return 0; }
    python3 - "$manifest" <<'PY'
import json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
c = (m.get("components") or {}).get("webconfig")
sha = ""
if isinstance(c, str):
    sha = c
elif isinstance(c, dict):
    sha = c.get("commit_sha", "") or ""
print(sha[:7])
PY
}

# Resolve the feed_readsb component's expected short commit SHA from the release
# manifest. Same shape as the webconfig extractor. Echoes the 7-char short SHA,
# or empty if no feed_readsb component is declared (the feed gate then no-ops).
_airplanes_runtime_manifest_feed_readsb_short_sha() {
    local manifest="$1"
    [[ -f "$manifest" ]] || { printf ''; return 0; }
    python3 - "$manifest" <<'PY'
import json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
c = (m.get("components") or {}).get("feed_readsb")
sha = ""
if isinstance(c, str):
    sha = c
elif isinstance(c, dict):
    sha = c.get("commit_sha", "") or ""
print(sha[:7])
PY
}

# Feed health gate: confirm airplanes-feed.service is active and the feed
# binary it runs resolves through the `current` symlink into the new release.
# Gate is "started cleanly + correct binary" ONLY — never connected/synced.
# Environmental state (no SDR, no upstream reachability) must NEVER trigger a
# rollback, so we deliberately do not probe feed connectivity or aircraft
# counts. The unit-active check (caller adds airplanes-feed.service to the
# aggregate probe) covers "started cleanly"; this function adds the
# "the running binary is the release's binary" invariant by confirming the
# managed-path symlink for feed-airplanes points into the active release.
#
# Args: <target_root> <expected-feed-readsb-short-sha>
# The short sha is currently informational only — the binary-identity proof is
# the symlink resolution below, which the managed_paths apply guarantees. We
# keep the arg so a future build-stamped feed binary can be version-probed.
_airplanes_runtime_probe_feed_binary_current() {
    local target_root="$1"
    local link="${target_root}/usr/local/share/airplanes/feed-airplanes"
    local current="${target_root}/opt/airplanes-runtime/current"
    if [[ ! -L "$link" ]]; then
        echo "ERROR: feed gate: $link is not a symlink (managed_paths not applied?)" >&2
        return 1
    fi
    local resolved current_resolved
    resolved="$(readlink -f "$link" 2>/dev/null || true)"
    current_resolved="$(readlink -f "$current" 2>/dev/null || true)"
    if [[ -z "$resolved" || -z "$current_resolved" ]]; then
        echo "ERROR: feed gate: could not resolve feed-airplanes ($link) or current ($current)" >&2
        return 1
    fi
    if [[ "$resolved" != "$current_resolved"/* ]]; then
        echo "ERROR: feed gate: feed-airplanes resolves to $resolved, outside active release $current_resolved" >&2
        return 1
    fi
    if [[ ! -x "$resolved" ]]; then
        echo "ERROR: feed gate: resolved feed binary not executable: $resolved" >&2
        return 1
    fi
    return 0
}

# Shared stability window cushion / cap (seconds). The window over which the
# unit-health gate re-confirms a set of units is max(effective RestartUSec) +
# cushion, capped to UNIT_WINDOW_MAX and to the remaining deadline budget.
AIRPLANES_RUNTIME_UNIT_WINDOW_CUSHION="${AIRPLANES_RUNTIME_UNIT_WINDOW_CUSHION:-10}"
AIRPLANES_RUNTIME_UNIT_WINDOW_MAX="${AIRPLANES_RUNTIME_UNIT_WINDOW_MAX:-60}"

# Parse a systemd time-span (the form `systemctl show -p RestartUSec --value`
# emits: "30s", "100ms", "1min 30s", "0", "infinity", or a bare integer of
# microseconds) to whole seconds, rounded up. Echoes the integer; non-zero
# exit on an unparseable span so the caller can fail closed.
_airplanes_runtime_parse_timespan_seconds() {
    python3 - "$1" <<'PY'
import sys, re, math
s = sys.argv[1].strip()
if s == "infinity":
    # No finite auto-restart cadence — nothing to wait out beyond the cushion.
    print(0); raise SystemExit(0)
if re.fullmatch(r"\d+", s):           # bare integer = microseconds
    print(int(math.ceil(int(s) / 1e6))); raise SystemExit(0)
units = {"us": 1e-6, "usec": 1e-6, "ms": 1e-3, "msec": 1e-3,
         "s": 1, "sec": 1, "second": 1, "seconds": 1,
         "min": 60, "m": 60, "h": 3600, "hr": 3600}
# Reject input that is not wholly composed of "<number><unit>" tokens, so
# partial garbage like "1s xyz" fails closed instead of silently yielding 1.
if not re.fullmatch(r"(?:\s*\d+(?:\.\d+)?\s*[a-zA-Z]+\s*)+", s):
    raise SystemExit(1)
total = 0.0; found = False
for m in re.finditer(r"(\d+(?:\.\d+)?)\s*([a-zA-Z]+)", s):
    u = m.group(2).lower()
    if u not in units:
        raise SystemExit(1)
    total += float(m.group(1)) * units[u]; found = True
if not found:
    raise SystemExit(1)
print(int(math.ceil(total)))
PY
}

_airplanes_runtime_unit_prop() {
    systemctl show "$1" -p "$2" --value 2>/dev/null
}

# Aggregate unit-health gate. Requires ALL named units to reach
# ActiveState=active within `deadline`, then hold active — with NRestarts
# unchanged and Result in {success, ""} — across ONE shared stability window.
#
# A bare `is-active` is insufficient: a Restart=always unit reads `active`
# momentarily between failures, so a crash-loop (e.g. tar1090 217/USER) would
# slip through. The HTTP probes alone also miss it: lighttpd serves
# tar1090/graphs1090 static dirs with 200 even when the service is dead, and
# readsb's aircraft.json can be stale-but-fresh from just before a crash.
#
# Fails closed (returns 1) when systemctl is unavailable or a RestartUSec span
# cannot be parsed — gates only run in runtime mode, where a missing systemctl
# is an error, not a reason to skip. Documented residual limit: a unit that
# crashes on a cadence slower than the window can still pass one window.
_airplanes_runtime_probe_units_active() {
    local deadline="$1"; shift
    local units=("$@")
    local u state nr result sub

    if ! command -v systemctl >/dev/null 2>&1; then
        echo "ERROR: probe_units_active: systemctl unavailable; failing closed" >&2
        return 1
    fi

    # Phase 1 — all units reach active within the deadline.
    local end=$(( $(date +%s) + deadline ))
    while :; do
        local all_active=1
        for u in "${units[@]}"; do
            state="$(_airplanes_runtime_unit_prop "$u" ActiveState)"
            [[ "$state" == "active" ]] || { all_active=0; break; }
        done
        (( all_active )) && break
        if (( $(date +%s) >= end )); then
            echo "ERROR: probe_units_active: not all units active within ${deadline}s (last: $u=$state)" >&2
            return 1
        fi
        sleep 1
    done

    # Phase 2 — shared window = max(effective RestartUSec) + cushion, capped.
    local window=0 rs sec
    for u in "${units[@]}"; do
        rs="$(_airplanes_runtime_unit_prop "$u" RestartUSec)"
        if ! sec="$(_airplanes_runtime_parse_timespan_seconds "$rs")"; then
            echo "ERROR: probe_units_active: unparseable RestartUSec='$rs' for $u; failing closed" >&2
            return 1
        fi
        (( sec > window )) && window=$sec
    done
    window=$(( window + AIRPLANES_RUNTIME_UNIT_WINDOW_CUSHION ))
    (( window > AIRPLANES_RUNTIME_UNIT_WINDOW_MAX )) && window=$AIRPLANES_RUNTIME_UNIT_WINDOW_MAX
    # Cap to the remaining deadline budget. If phase 1 already exhausted it
    # (remaining <= 0) the cap drives window non-positive and the floor below
    # pins it to a 1s final confirmation rather than running the full window
    # past the deadline.
    local remaining=$(( end - $(date +%s) ))
    (( window > remaining )) && window=$remaining
    (( window < 1 )) && window=1

    # Phase 3 — snapshot NRestarts (fail closed on a non-numeric read), then
    # hold the window re-confirming health. The loop checks BEFORE each sleep
    # and once more when the window expires, so a flap in the final interval is
    # not missed.
    local -A base_restarts
    for u in "${units[@]}"; do
        nr="$(_airplanes_runtime_unit_prop "$u" NRestarts)"
        if ! [[ "$nr" =~ ^[0-9]+$ ]]; then
            echo "ERROR: probe_units_active: non-numeric NRestarts='$nr' for $u; failing closed" >&2
            return 1
        fi
        base_restarts["$u"]="$nr"
    done
    local hold_end=$(( $(date +%s) + window ))
    while :; do
        for u in "${units[@]}"; do
            state="$(_airplanes_runtime_unit_prop "$u" ActiveState)"
            nr="$(_airplanes_runtime_unit_prop "$u" NRestarts)"
            result="$(_airplanes_runtime_unit_prop "$u" Result)"
            if [[ "$state" != "active" ]] \
                    || ! [[ "$nr" =~ ^[0-9]+$ ]] \
                    || [[ "$nr" != "${base_restarts[$u]}" ]] \
                    || { [[ -n "$result" ]] && [[ "$result" != "success" ]]; }; then
                sub="$(_airplanes_runtime_unit_prop "$u" SubState)"
                echo "ERROR: probe_units_active: $u unstable (ActiveState=$state SubState=$sub Result=$result NRestarts=$nr base=${base_restarts[$u]})" >&2
                return 1
            fi
        done
        (( $(date +%s) >= hold_end )) && break
        sleep 1
    done
    return 0
}

# Runs every health gate, in declared order. Returns 0 only if every gate
# passes within its deadline. Caller handles rollback on non-zero return.
airplanes_runtime_run_health_gates() {
    local target_root="$1"
    local deadline="${AIRPLANES_RUNTIME_HEALTH_DEADLINE}"

    # Unit-health gate FIRST: a crash-looping decoder/web unit would otherwise
    # pass the HTTP probes (lighttpd's static 200) or the aircraft.json
    # freshness check (stale pre-crash file). readsb's is-active is NOT
    # SDR-dependent — the daemon is active with zero aircraft.
    # Feed is gated only when the release declares a feed_readsb component
    # (a decoder-only release does not ship the feed binary/unit). Read the
    # active release manifest — `current` already points at the new release at
    # health-gate time.
    local active_manifest="${target_root}/opt/airplanes-runtime/current/manifest.json"
    local feed_short
    feed_short="$(_airplanes_runtime_manifest_feed_readsb_short_sha "$active_manifest")"

    local -a active_units=(
        readsb.service tar1090.service graphs1090.service
        airplanes-webconfig.service
    )
    if [[ -n "$feed_short" ]]; then
        active_units+=(airplanes-feed.service)
    fi
    if ! _airplanes_runtime_probe_units_active "$deadline" "${active_units[@]}"; then
        return 1
    fi

    # Feed binary-identity gate: the running feed binary must be the release's.
    # NOT connected/synced — environmental state must never trigger rollback.
    # airplanes-mlat.service is deliberately NOT gated: it is opt-in and on an
    # unconfigured feeder the wrapper self-disables (sleeps) or refuses to start
    # (misconfigured), neither of which is an update failure.
    if [[ -n "$feed_short" ]]; then
        if ! _airplanes_runtime_probe_feed_binary_current "$target_root"; then
            return 1
        fi
    fi

    # readsb: aircraft.json fresh + tar1090 HTTP probe.
    local aircraft_json="${target_root}/run/readsb/aircraft.json"
    if ! _airplanes_runtime_probe_file_freshness "$aircraft_json" 30 "$deadline"; then
        return 1
    fi
    if ! _airplanes_runtime_probe_http_200 "${AIRPLANES_RUNTIME_PROBE_URL_BASE}/tar1090/data/aircraft.json" "$deadline"; then
        return 1
    fi

    # UAT services (978): both produce key-value state files.
    if ! _airplanes_runtime_probe_uat_state "${target_root}/run/dump978-fa/state" "$deadline"; then
        return 1
    fi
    if ! _airplanes_runtime_probe_uat_state "${target_root}/run/airplanes-978/state" "$deadline"; then
        return 1
    fi

    # Webserver mounts.
    if ! _airplanes_runtime_probe_http_200 "${AIRPLANES_RUNTIME_PROBE_URL_BASE}/tar1090/"   "$deadline"; then
        return 1
    fi
    if ! _airplanes_runtime_probe_http_200 "${AIRPLANES_RUNTIME_PROBE_URL_BASE}/graphs1090/" "$deadline"; then
        return 1
    fi

    # Webconfig: probe /health THROUGH lighttpd (port 80) and confirm the
    # serving binary carries the release's webconfig commit. Reads the
    # expected short SHA from the active release manifest (the `current`
    # symlink already points at the new release at health-gate time). Skipped
    # when the release declares no webconfig component (decoder-only release).
    # active_manifest was resolved above with the feed gate.
    local wc_short
    wc_short="$(_airplanes_runtime_manifest_webconfig_short_sha "$active_manifest")"
    if [[ -n "$wc_short" ]]; then
        if ! _airplanes_runtime_probe_webconfig_version \
                "${AIRPLANES_RUNTIME_PROBE_URL_BASE}/health" "$wc_short" "$deadline"; then
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Compatibility preflight (runtime mode only, hard-fail per decision 10)
# ---------------------------------------------------------------------------

# Parse a semver-range string ("`>=2.1.0,<2.3.0`", "`>=14`") against a
# concrete semver and emit 0/1 via exit code. We accept a comma-separated
# list of clauses; each clause is an operator (>=, <=, >, <, =, ==) and a
# semver. Every clause must hold. The semver does not need patch precision
# — missing components default to 0.
_airplanes_runtime_semver_satisfies() {
    local installed="$1" range="$2"

    if [[ -z "$range" ]]; then
        # No constraint → satisfied.
        return 0
    fi

    python3 - "$installed" "$range" <<'PY'
import re
import sys

installed_str, range_str = sys.argv[1], sys.argv[2]

def parse(s):
    # Accept "X", "X.Y", "X.Y.Z" — return a 3-tuple. Anchored at both ends
    # so a string like "2.2.5-dev" does NOT satisfy a "<2.3.0" upper bound:
    # the prerelease suffix on the installed version is a real ordering
    # question (most semver pre-release rules sort prereleases BEFORE the
    # same-triple stable). v1 treats anything with extra trailing junk as
    # a parse error so the operator sees the mismatch instead of a silent
    # downgrade or compat false-pass.
    m = re.match(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?$', s.strip())
    if not m:
        raise SystemExit(2)
    return tuple(int(g or 0) for g in m.groups())

try:
    installed = parse(installed_str)
except SystemExit:
    sys.exit(1)

clauses = [c.strip() for c in range_str.split(',') if c.strip()]
ok = True
for clause in clauses:
    m = re.match(r'^(>=|<=|>|<|==|=)?\s*(.+)$', clause)
    if not m:
        sys.exit(1)
    op = m.group(1) or '=='
    try:
        rhs = parse(m.group(2))
    except SystemExit:
        sys.exit(1)
    if   op in ('==', '='): cmp_ok = (installed == rhs)
    elif op == '>=':        cmp_ok = (installed >= rhs)
    elif op == '<=':        cmp_ok = (installed <= rhs)
    elif op == '>':         cmp_ok = (installed >  rhs)
    elif op == '<':         cmp_ok = (installed <  rhs)
    else:
        sys.exit(1)
    if not cmp_ok:
        ok = False
        break
sys.exit(0 if ok else 1)
PY
}

# Resolve installed webconfig version from /etc/airplanes/webconfig-release.json's
# `version` field. Missing → empty.
_airplanes_runtime_read_installed_webconfig_version() {
    local target_root="$1"
    local f="${target_root}/etc/airplanes/webconfig-release.json"
    [[ -r "$f" ]] || { printf ''; return 0; }
    python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("version",""))
except Exception:
    pass' "$f" 2>/dev/null || true
}

# Resolve installed feed contract version. Two possible locations; whichever
# exists first wins. Missing → "0" so a constraint other than `>=0` fails.
_airplanes_runtime_read_installed_feed_contract() {
    local target_root="$1"
    local candidates=(
        "${target_root}/usr/local/share/airplanes/lib/feed-contract-version"
        "${target_root}/etc/airplanes/feed-contract"
    )
    local f
    for f in "${candidates[@]}"; do
        if [[ -r "$f" ]]; then
            head -n1 "$f" | tr -d '[:space:]'
            return 0
        fi
    done
    printf '%s' "0"
}

# Resolve installed image-base version from /etc/airplanes/build-manifest.json.
# Schema is image-side; we read `version` (the convention image-build uses).
_airplanes_runtime_read_installed_image_base() {
    local target_root="$1"
    local f="${target_root}/etc/airplanes/build-manifest.json"
    [[ -r "$f" ]] || { printf '0'; return 0; }
    python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("version","0") or "0")
except Exception:
    print("0")' "$f" 2>/dev/null || printf '0'
}

# Compare two dotted-triple semvers. Echoes -1/0/1 for a<b / a==b / a>b.
# Missing components default to 0. Non-numeric input fails closed (exit 2).
_airplanes_runtime_semver_cmp() {
    python3 - "$1" "$2" <<'PY'
import re, sys
def parse(s):
    m = re.match(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?$', s.strip())
    if not m:
        raise SystemExit(2)
    return tuple(int(g or 0) for g in m.groups())
a, b = parse(sys.argv[1]), parse(sys.argv[2])
print(-1 if a < b else (1 if a > b else 0))
PY
}

# Resolve the installed Debian suite codename from /etc/os-release
# (VERSION_CODENAME). Falls back to lsb_release if os-release is unreadable.
# Missing → empty.
_airplanes_runtime_read_os_codename() {
    local target_root="$1"
    local f="${target_root}/etc/os-release"
    if [[ -r "$f" ]]; then
        local cn
        cn="$(sed -n 's/^VERSION_CODENAME=//p' "$f" | head -n1 | tr -d '"'"'"' \t\r\n')"
        if [[ -n "$cn" ]]; then
            printf '%s' "$cn"
            return 0
        fi
    fi
    # Only consult the live system when not rebased under a test root.
    if [[ -z "$target_root" || "$target_root" == "/" ]] && command -v lsb_release >/dev/null 2>&1; then
        lsb_release -cs 2>/dev/null | tr -d '[:space:]'
        return 0
    fi
    printf ''
}

# Read the installed CPython ABI tag (e.g. "cp313") from the target root's
# python3 interpreter. Build mode uses the host python3; runtime mode uses the
# chroot's /usr/bin/python3. Missing → empty.
_airplanes_runtime_read_python_abi() {
    local target_root="$1"
    local py="${target_root}/usr/bin/python3"
    # In build mode or on live system, python3 may not be chroot-invocable but
    # is directly available on PATH.
    if [[ -z "$target_root" || "$target_root" == "/" ]]; then
        py="python3"
    fi
    # Run the real interpreter (or the host one for live system).
    "$py" -c 'import sys; print("cp%d%d" % (sys.version_info[0], sys.version_info[1]))' 2>/dev/null || true
}

# Free bytes available on the filesystem hosting the releases dir. Echoes the
# integer byte count, or empty if it can't be determined.
_airplanes_runtime_free_bytes_for_releases() {
    local target_root="$1"
    local dir="${target_root}/opt/airplanes-runtime/releases"
    # Walk up to the nearest existing ancestor — the releases dir may not
    # exist yet on a first install.
    while [[ ! -d "$dir" && -n "$dir" && "$dir" != "/" ]]; do
        dir="$(dirname "$dir")"
    done
    [[ -d "$dir" ]] || dir="${target_root:-/}"
    [[ -d "$dir" ]] || dir="/"
    # `df -P -B1` reports POSIX-portable 1-byte blocks; field 4 is available.
    df -P -B1 "$dir" 2>/dev/null | awk 'NR==2 { print $4 }'
}

airplanes_runtime_run_compat_preflight() {
    local manifest="$1" target_root="$2"

    # --- Forward-compat floor (top-level fields, always checked) ----------
    #
    # A manifest declaring a schema version or installer floor this updater
    # does not meet is refused BEFORE any mutation, so an old updater never
    # half-interprets a newer release.
    local manifest_schema installer_min
    manifest_schema="$(jq -r '.manifest_schema_version // empty' "$manifest")"
    if [[ -n "$manifest_schema" ]]; then
        if ! [[ "$manifest_schema" =~ ^[0-9]+$ ]]; then
            echo "ERROR: compat preflight: manifest_schema_version is not an integer: '$manifest_schema'" >&2
            return 1
        fi
        if (( manifest_schema > AIRPLANES_RUNTIME_INSTALLER_SCHEMA_VERSION )); then
            echo "ERROR: compat preflight: release manifest_schema_version=$manifest_schema exceeds this updater's supported schema ($AIRPLANES_RUNTIME_INSTALLER_SCHEMA_VERSION)" >&2
            echo "       Update the on-device runtime overlay through an intermediate release first." >&2
            return 1
        fi
    fi

    installer_min="$(jq -r '.installer_min_version // empty' "$manifest")"
    if [[ -n "$installer_min" ]]; then
        local cmp
        if ! cmp="$(_airplanes_runtime_semver_cmp "$AIRPLANES_RUNTIME_INSTALLER_VERSION" "$installer_min")"; then
            echo "ERROR: compat preflight: could not compare installer_min_version='$installer_min'" >&2
            return 1
        fi
        if (( cmp < 0 )); then
            echo "ERROR: compat preflight: release requires updater >= $installer_min but this updater is $AIRPLANES_RUNTIME_INSTALLER_VERSION" >&2
            echo "       Update the on-device runtime overlay through an intermediate release first." >&2
            return 1
        fi
    fi

    # --- Free-space preflight (always checked, before extraction) ---------
    #
    # The release tree plus the retained previous release must fit. A tight
    # card should fail cleanly here rather than half-extract and wedge.
    local free_bytes
    free_bytes="$(_airplanes_runtime_free_bytes_for_releases "$target_root")"
    if [[ -n "$free_bytes" && "$free_bytes" =~ ^[0-9]+$ ]]; then
        if (( free_bytes < AIRPLANES_RUNTIME_MIN_FREE_BYTES )); then
            echo "ERROR: compat preflight: insufficient free space for extraction: ${free_bytes}B free, need >= ${AIRPLANES_RUNTIME_MIN_FREE_BYTES}B" >&2
            return 1
        fi
    fi

    if ! jq -e '.compat' "$manifest" >/dev/null 2>&1; then
        # No compat block declared → nothing further to enforce.
        return 0
    fi

    # --- Base-OS codename (compat.base_os_codename) -----------------------
    local want_codename
    want_codename="$(jq -r '.compat.base_os_codename // ""' "$manifest")"
    if [[ -n "$want_codename" ]]; then
        local have_codename
        have_codename="$(_airplanes_runtime_read_os_codename "$target_root")"
        if [[ -z "$have_codename" ]]; then
            echo "ERROR: compat preflight: release targets base OS '$want_codename' but the installed OS codename could not be determined" >&2
            return 1
        fi
        if [[ "$have_codename" != "$want_codename" ]]; then
            echo "ERROR: compat preflight: release targets base OS '$want_codename' but this device runs '$have_codename'" >&2
            echo "       A base-OS major upgrade is reflash-only; this release cannot be installed in place." >&2
            return 1
        fi
    fi

    # --- Python ABI (compat.mlat_python_abi) --------------------------------
    # The prebuilt mlat-client venv contains a compiled C extension locked to a
    # specific CPython ABI. If the base OS ships a different Python, the venv
    # would segfault or fail to import; refuse cleanly instead.
    local want_abi
    want_abi="$(jq -r '.compat.mlat_python_abi // ""' "$manifest")"
    if [[ -n "$want_abi" ]]; then
        local have_abi
        have_abi="$(_airplanes_runtime_read_python_abi "$target_root")"
        if [[ -z "$have_abi" ]]; then
            echo "ERROR: compat preflight: release requires Python ABI '$want_abi' but python3 is not installed" >&2
            return 1
        fi
        if [[ "$have_abi" != "$want_abi" ]]; then
            echo "ERROR: compat preflight: release mlat-client venv was built against Python ABI '$want_abi' but this device has '$have_abi'" >&2
            echo "       A base-OS Python upgrade is required; reflash with a matching image." >&2
            return 1
        fi
    fi

    local req
    req="$(jq -r '.compat.requires_webconfig // ""' "$manifest")"
    if [[ -n "$req" ]]; then
        local installed
        installed="$(_airplanes_runtime_read_installed_webconfig_version "$target_root")"
        if [[ -z "$installed" ]]; then
            echo "ERROR: compat preflight: requires_webconfig='$req' but installed webconfig version not found" >&2
            echo "       Expected /etc/airplanes/webconfig-release.json with a .version field." >&2
            return 1
        fi
        if ! _airplanes_runtime_semver_satisfies "$installed" "$req"; then
            echo "ERROR: compat preflight: installed webconfig $installed does not satisfy '$req'" >&2
            return 1
        fi
    fi

    req="$(jq -r '.compat.requires_feed_contract // ""' "$manifest")"
    if [[ -n "$req" ]]; then
        local installed
        installed="$(_airplanes_runtime_read_installed_feed_contract "$target_root")"
        if ! _airplanes_runtime_semver_satisfies "$installed" "$req"; then
            echo "ERROR: compat preflight: installed feed contract $installed does not satisfy '$req'" >&2
            return 1
        fi
    fi

    req="$(jq -r '.compat.min_image_base // ""' "$manifest")"
    if [[ -n "$req" ]]; then
        local installed
        installed="$(_airplanes_runtime_read_installed_image_base "$target_root")"
        if ! _airplanes_runtime_semver_satisfies "$installed" "$req"; then
            echo "ERROR: compat preflight: image base $installed does not satisfy '$req'" >&2
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Runtime-manifest pointer
# ---------------------------------------------------------------------------

airplanes_runtime_record_runtime_manifest() {
    local target_root="$1"
    local link="${target_root}/etc/airplanes/runtime-manifest.json"
    install -d -m 755 "$(dirname "$link")"
    local tmp="${link}.tmp.$$"
    rm -f -- "$tmp"

    if airplanes_runtime_is_build_mode; then
        # Build mode: write a regular file copy so host-side consumers (like
        # scripts/manifest-generator.sh running in stage 07-finalize, outside
        # the chroot) can read the manifest content. The symlink form points
        # at /opt/airplanes-runtime/current/manifest.json which the host
        # cannot resolve when target_root != /. The first runtime self-update
        # on-device replaces this file with the symlink via `mv -Tf`, so the
        # auto-follow-current semantics take over once the device is live.
        #
        # The `current` symlink target is an absolute path rooted at the
        # device's view of /, so resolve it manually against target_root
        # rather than letting `readlink -f` follow it on the host.
        local current="${target_root}/opt/airplanes-runtime/current"
        local current_target
        current_target="$(readlink -- "$current")" || {
            echo "ERROR: ${current} is not a symlink (current pointer missing)" >&2
            return 1
        }
        local manifest_src="${target_root}${current_target}/manifest.json"
        if [[ ! -f "$manifest_src" ]]; then
            echo "ERROR: current release manifest missing: $manifest_src" >&2
            return 1
        fi
        cp -- "$manifest_src" "$tmp"
        chmod 0644 "$tmp"
    else
        ln -s -- "/opt/airplanes-runtime/current/manifest.json" "$tmp"
    fi

    mv -Tf -- "$tmp" "$link"
}

# ---------------------------------------------------------------------------
# Last-good-release pointer
# ---------------------------------------------------------------------------
#
# Image-owned file at /var/lib/airplanes-runtime/last-good-release recording
# the device-canonical path of the most recent release that passed its health
# gates. The boot recovery shim uses it as the rollback target when the state
# file's prev_release is missing or invalid. Written at (not after) the
# HEALTH_PASSED transition so a reboot in the cleanup window cannot leave it
# stale relative to a known-good release.

AIRPLANES_RUNTIME_LAST_GOOD_REL="${AIRPLANES_RUNTIME_LAST_GOOD_REL:-var/lib/airplanes-runtime/last-good-release}"

airplanes_runtime_write_last_good_release() {
    local target_root="$1" on_device_release="$2"
    if [[ "$on_device_release" != /* ]]; then
        echo "ERROR: write_last_good_release: release path must be absolute (got: $on_device_release)" >&2
        return 1
    fi
    local f="${target_root%/}/${AIRPLANES_RUNTIME_LAST_GOOD_REL}"
    install -d -m 755 "$(dirname "$f")"
    local tmp="${f}.tmp.$$"
    if ! printf '%s\n' "$on_device_release" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    sync -d "$tmp" 2>/dev/null || true
    mv -Tf -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
    sync -d "$(dirname "$f")" 2>/dev/null || true
}

# Finalize the post-HEALTH_PASSED cleanup. Idempotent and resumable — runs the
# runtime-manifest pointer write (fatal on failure: callers must retry) and a
# best-effort GC. Reused by both the forward walk and the resume-on-entry path
# so a HEALTH_PASSED interruption is finished by the next updater invocation.
airplanes_runtime_finalize_after_health_passed() {
    local target_root="$1"

    # Remove RETIRED symlinks — FHS links the prior release owned that the
    # new release does not. Done INSIDE finalize (rather than inline in the
    # forward walk) so the HEALTH_PASSED resume path — re-entry after a power
    # loss in the cleanup window — also performs it; otherwise retired links
    # could persist indefinitely. prev/new release dirs are read from the
    # state file, which persists them across transitions. Best-effort,
    # idempotent, and skipped on first install or once GC has removed the
    # prior release dir. Runs before manifest-record + GC so the prior
    # manifest is still on disk when we diff against it.
    local prev new
    prev="$(airplanes_runtime_state_get "$target_root" prev_release)"
    new="$(airplanes_runtime_state_get  "$target_root" new_release)"
    if [[ -n "$prev" && -f "$prev/manifest.json" && -n "$new" && -f "$new/manifest.json" ]]; then
        airplanes_runtime_remove_retired_symlinks \
            "$prev/manifest.json" "$new/manifest.json" "$target_root" || true
    fi

    if ! airplanes_runtime_record_runtime_manifest "$target_root"; then
        echo "ERROR: finalize_after_health_passed: runtime manifest pointer write failed" >&2
        return 1
    fi

    # Start newly-enabled activators (*.timer / *.path) so an in-place
    # self-update doesn't leave them idle until next reboot. Uses the
    # state-file's `new_release` (already resolved above) for the manifest
    # path — `current/manifest.json` would round-trip through an absolute
    # on-device symlink and break under rebased target roots in tests
    # (see the relpath comment around the runtime-manifest-record path).
    # Best-effort; runs AFTER the health gate has already validated the
    # release, so a failure here is non-fatal and does not roll back.
    # Empty $new means absent/malformed/legacy state, not first install
    # (first install has empty prev_release but new_release is written at
    # STARTED). Skipping keeps finalize non-fatal for malformed/legacy
    # state; the activator gap on this release waits for next reboot, when
    # timers.target arms whatever the manifest enabled.
    if [[ -n "$new" && -f "$new/manifest.json" ]]; then
        if ! airplanes_runtime_start_enabled_activators "$new/manifest.json"; then
            echo "WARN: finalize_after_health_passed: activator start reported a failure (non-fatal)" >&2
        fi
    fi

    if ! airplanes_runtime_gc_old_releases "$target_root"; then
        echo "WARN: finalize_after_health_passed: GC of old releases reported a failure (non-fatal)" >&2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Old-release GC
# ---------------------------------------------------------------------------
#
# Keep at most AIRPLANES_RUNTIME_RETAIN_RELEASES under
# /opt/airplanes-runtime/releases/. The current-pointed release is always
# retained even if it would otherwise be GC'd.

airplanes_runtime_gc_old_releases() {
    local target_root="$1"
    local releases_dir="${target_root}/opt/airplanes-runtime/releases"
    [[ -d "$releases_dir" ]] || return 0
    local current_target=""
    if [[ -L "${target_root}/opt/airplanes-runtime/current" ]]; then
        current_target="$(readlink -f "${target_root}/opt/airplanes-runtime/current")"
    fi
    # List release dirs sorted by mtime newest-first, drop the top N.
    local -a victims=()
    local kept=0 d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        if [[ "$(readlink -f "$d")" == "$current_target" ]]; then
            continue
        fi
        kept=$(( kept + 1 ))
        if (( kept >= AIRPLANES_RUNTIME_RETAIN_RELEASES )); then
            victims+=("$d")
        fi
    done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\0' \
                | sort -z -nr -k1,1 \
                | tr '\0' '\n' \
                | awk '{ $1=""; sub(/^ /,""); print }')
    local v
    for v in "${victims[@]}"; do
        rm -rf -- "$v"
    done
}

# ---------------------------------------------------------------------------
# Orchestrator: install-step pipeline
# ---------------------------------------------------------------------------
#
# This function is the end-to-end runtime install path (post-preflight). It
# is intentionally a single function so the follow-up self-update helper can
# wrap it with the state machine and flock without re-doing the per-step
# wiring. Build mode skips systemd ops and health gates.

airplanes_runtime_run_install_steps() {
    local manifest="$1" release_dir="$2" target_root="$3"

    if ! airplanes_runtime_is_build_mode; then
        airplanes_runtime_backup_all_mutable_paths "$manifest" "$release_dir" "$target_root" || return 1
        airplanes_runtime_run_migrations_forward "$manifest" "$release_dir" "$target_root" || return 1
    fi

    # Flip current to the new release. In build mode the link is rebased
    # under ROOTFS_DIR.
    local abs_release_dir
    if airplanes_runtime_is_build_mode; then
        # In build mode the on-device path the link points at is /opt/...
        # (relative to the rootfs, not the host). Strip TARGET_ROOT.
        local rel="${release_dir#"$target_root"}"
        abs_release_dir="$rel"
    else
        abs_release_dir="$release_dir"
    fi
    airplanes_runtime_flip_current "$abs_release_dir" "$target_root" || return 1

    airplanes_runtime_relink_decoder_binaries "$target_root" || return 1
    airplanes_runtime_apply_managed_paths "$manifest" "$release_dir" "$target_root" || return 1

    # The runtime-manifest pointer is meaningful in both modes. At runtime
    # it lets the orchestrator inspect the active release; at build time
    # manifest-generator.sh reads component SHAs through it. Pure symlink
    # update, no systemd or network — safe to run in build mode.
    airplanes_runtime_record_runtime_manifest "$target_root" || return 1

    if ! airplanes_runtime_is_build_mode; then
        airplanes_runtime_apply_systemd_ops "$manifest" || return 1
        airplanes_runtime_run_health_gates "$target_root" || return 1
        # Start newly-enabled activators (*.timer / *.path) post-health-gate.
        # Same posture as the finalize-side call: best-effort, warn-and-
        # continue. The state-machine self-update path drives this from
        # finalize_after_health_passed; install.sh --runtime drives it here.
        if ! airplanes_runtime_start_enabled_activators "$manifest"; then
            echo "WARN: run_install_steps: activator start reported a failure (non-fatal)" >&2
        fi
        airplanes_runtime_gc_old_releases "$target_root" || return 1
    fi
}

# ---------------------------------------------------------------------------
# Upgrade state file
# ---------------------------------------------------------------------------
#
# Helpers consumed by the self-update orchestrator and the boot-time recovery
# oneshot. The state file lives at
# ${target_root}/var/lib/airplanes-runtime-upgrade/upgrade-state and persists
# the position of an in-flight upgrade across a power loss so the boot-time
# recovery script can finish or undo whatever the orchestrator started.
#
# Format: one key=value pair per line. Recognised keys:
#   state         one of:
#                   CLEAN | STARTED | PAYLOAD_EXTRACTED |
#                   MIGRATIONS_FORWARD_DONE | SYMLINK_FLIPPED |
#                   SYSTEMD_OPS_DONE | HEALTH_RUNNING | HEALTH_PASSED |
#                   INSTALLED | FAILED_PRE_MUTATION | ROLLED_BACK_<from>_TO_<to>
#   prev_release  absolute path the `current` symlink targeted at STARTED.
#                 Preserved across the entire attempt so a recovery from
#                 SYMLINK_FLIPPED still knows what to roll back to.
#   new_release   absolute path of the release dir being installed.
#   started_at    RFC3339 UTC timestamp the attempt was opened at.
#   failure_reason optional free-text reason captured on terminal failure.

# Path constants; uppercase so a caller can override per test (the test
# fixture rebases STATE_DIR under BATS_TEST_TMPDIR).
AIRPLANES_RUNTIME_STATE_DIR_REL="${AIRPLANES_RUNTIME_STATE_DIR_REL:-var/lib/airplanes-runtime-upgrade}"
AIRPLANES_RUNTIME_STATE_FILE_NAME="${AIRPLANES_RUNTIME_STATE_FILE_NAME:-upgrade-state}"
AIRPLANES_RUNTIME_LOCK_FILE="${AIRPLANES_RUNTIME_LOCK_FILE:-/run/airplanes/runtime-update.lock}"

airplanes_runtime_state_dir() {
    local target_root="$1"
    printf '%s/%s' "${target_root%/}" "$AIRPLANES_RUNTIME_STATE_DIR_REL"
}

airplanes_runtime_state_file() {
    local target_root="$1"
    printf '%s/%s' "$(airplanes_runtime_state_dir "$target_root")" \
        "$AIRPLANES_RUNTIME_STATE_FILE_NAME"
}

# Create the state directory with the documented mode. Idempotent.
airplanes_runtime_ensure_state_dir() {
    local target_root="$1"
    install -d -m 755 "$(airplanes_runtime_state_dir "$target_root")"
}

# Read a single key from the state file. Echoes the value or empty string.
# Caller distinguishes "key missing" from "value empty" via the broader
# state-read which checks `state=` is present and recognised.
airplanes_runtime_state_get() {
    local target_root="$1" key="$2"
    local f
    f="$(airplanes_runtime_state_file "$target_root")"
    [[ -r "$f" ]] || { printf ''; return 0; }
    awk -F= -v k="$key" '
        $0 ~ "^[[:space:]]*"k"=" {
            sub("^[[:space:]]*"k"=", "")
            sub("[[:space:]]*$", "")
            print
            exit
        }
    ' "$f"
}

# Read the state name. Echoes one of the documented state strings, or CLEAN
# when the file is absent. A malformed/empty file echoes UNKNOWN so the
# caller can fail-closed.
airplanes_runtime_state_read() {
    local target_root="$1"
    local f
    f="$(airplanes_runtime_state_file "$target_root")"
    if [[ ! -e "$f" ]]; then
        printf 'CLEAN'
        return 0
    fi
    local s
    s="$(airplanes_runtime_state_get "$target_root" state)"
    if [[ -z "$s" ]]; then
        printf 'UNKNOWN'
        return 0
    fi
    printf '%s' "$s"
}

# Atomic state write. Re-uses any prev_release / new_release / started_at
# values already present in the file unless the caller overrides them via
# the optional named arguments. Layout (intentionally rigid so a partial
# read mid-rename never sees a different shape):
#
#   state=<state>
#   prev_release=<abs path or empty>
#   new_release=<abs path or empty>
#   started_at=<RFC3339 UTC>
#   failure_reason=<free text, only when supplied>
#
# Usage:
#   airplanes_runtime_state_write <target_root> <state> \
#       [prev_release=<path>] [new_release=<path>] \
#       [started_at=<rfc3339>] [failure_reason=<text>]
airplanes_runtime_state_write() {
    local target_root="$1" new_state="$2"; shift 2
    airplanes_runtime_ensure_state_dir "$target_root"

    local prev_release new_release started_at failure_reason
    prev_release="$(airplanes_runtime_state_get "$target_root" prev_release)"
    new_release="$(airplanes_runtime_state_get "$target_root"  new_release)"
    started_at="$(airplanes_runtime_state_get  "$target_root"  started_at)"
    failure_reason=""

    local kv
    for kv in "$@"; do
        case "$kv" in
            prev_release=*)   prev_release="${kv#prev_release=}" ;;
            new_release=*)    new_release="${kv#new_release=}" ;;
            started_at=*)     started_at="${kv#started_at=}" ;;
            failure_reason=*) failure_reason="${kv#failure_reason=}" ;;
            *)
                echo "ERROR: airplanes_runtime_state_write: unknown kv pair: $kv" >&2
                return 2
                ;;
        esac
    done

    local f tmp
    f="$(airplanes_runtime_state_file "$target_root")"
    tmp="${f}.tmp.$$"
    if ! {
        printf 'state=%s\n'        "$new_state"
        printf 'prev_release=%s\n' "$prev_release"
        printf 'new_release=%s\n'  "$new_release"
        printf 'started_at=%s\n'   "$started_at"
        if [[ -n "$failure_reason" ]]; then
            printf 'failure_reason=%s\n' "$failure_reason"
        fi
    } > "$tmp"; then
        echo "ERROR: airplanes_runtime_state_write: write to $tmp failed (state=$new_state)" >&2
        rm -f -- "$tmp"
        return 1
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    # sync the file's data so a power-loss between this and the rename
    # commit on ext4 still sees the staged content. Non-fatal if -d is
    # unsupported by the host (the directory sync below covers the rename).
    sync -d "$tmp" 2>/dev/null || true
    if ! mv -Tf -- "$tmp" "$f"; then
        echo "ERROR: airplanes_runtime_state_write: rename $tmp -> $f failed (state=$new_state)" >&2
        rm -f -- "$tmp"
        return 1
    fi
    sync -d "$(airplanes_runtime_state_dir "$target_root")" 2>/dev/null || true
    return 0
}

# Clear the state file (after a terminal good state has been acted on, or
# before a fresh attempt). Removes the file rather than writing CLEAN — an
# absent file is the canonical CLEAN representation.
airplanes_runtime_state_clear() {
    local target_root="$1"
    local f
    f="$(airplanes_runtime_state_file "$target_root")"
    rm -f -- "$f"
}

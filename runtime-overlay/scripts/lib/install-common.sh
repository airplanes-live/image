# shellcheck shell=bash
#
# install-common.sh — shared helpers for the runtime overlay's on-device
# install/update path.
#
# Sourced by:
#   - runtime-overlay/install.sh                              (build mode + runtime mode)
#   - runtime-overlay/update.sh                               (runtime mode shim)
#   - runtime-overlay/src/lib/runtime-self-update.sh          (state-machine wrapper)
#   - runtime-overlay/src/lib/airplanes-runtime-update-recover.sh (boot recovery oneshot)
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

AIRPLANES_RUNTIME_REPO="${AIRPLANES_RUNTIME_REPO:-https://github.com/airplanes-live/image.git}"
AIRPLANES_RUNTIME_DOWNLOAD_BASE="${AIRPLANES_RUNTIME_DOWNLOAD_BASE:-https://github.com/airplanes-live/image/releases/download}"
AIRPLANES_RUNTIME_RELEASES_API="${AIRPLANES_RUNTIME_RELEASES_API:-https://api.github.com/repos/airplanes-live/image/releases}"

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
# Build mode reads AIRPLANES_RUNTIME_OVERLAY_TAG (a concrete tag pinned by
# the image config — `runtime-vX.Y.Z` for stable, `runtime-dev-YYYYMMDD-<sha>`
# for dev). Runtime mode reads /etc/airplanes/release-channel; the file
# doesn't exist during image build because stage 06 writes it after stage 02.

airplanes_runtime_resolve_channel() {
    if airplanes_runtime_is_build_mode; then
        if [[ -z "${AIRPLANES_RUNTIME_OVERLAY_TAG:-}" ]]; then
            echo "ERROR: AIRPLANES_RUNTIME_OVERLAY_TAG must be set in build mode (concrete tag pinned by the image config)" >&2
            return 1
        fi
        # Build mode doesn't have a channel of its own — return what the
        # caller pinned so the rest of the pipeline can echo it for clarity.
        printf '%s' "pinned"
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

# Resolves a channel name into a concrete release tag. Identical pattern to
# image-webconfig's resolver: stable picks the highest semver matching
# `runtime-v[MAJOR].[MINOR].[PATCH]` exactly (no prereleases); dev returns
# the floating `runtime-dev-latest` tag.
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
            if [[ -z "${AIRPLANES_RUNTIME_OVERLAY_TAG:-}" ]]; then
                echo "ERROR: pinned channel selected but AIRPLANES_RUNTIME_OVERLAY_TAG is empty" >&2
                return 1
            fi
            printf '%s' "${AIRPLANES_RUNTIME_OVERLAY_TAG}"
            ;;
        *)
            printf '%s' "$channel"
            ;;
    esac
}

# Strict match: runtime-vMAJOR.MINOR.PATCH, no leading zeroes, no prereleases.
# Echoes the highest matching tag (semver-sort via `sort -V`).
airplanes_runtime_resolve_latest_stable_tag() {
    local refs latest=""
    if ! refs="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$AIRPLANES_RUNTIME_REPO" 'refs/tags/runtime-v*' 2>/dev/null)"; then
        echo "ERROR: could not query release tags from $AIRPLANES_RUNTIME_REPO (network/DNS/TLS failure)" >&2
        return 2
    fi
    if [[ -z "$refs" ]]; then
        echo "ERROR: stable channel selected but no runtime-v[MAJOR].[MINOR].[PATCH] tags exist at $AIRPLANES_RUNTIME_REPO" >&2
        return 1
    fi
    local _sha _refname _tag
    while IFS=$'\t' read -r _sha _refname; do
        _tag="${_refname#refs/tags/}"
        if [[ "$_tag" =~ ^runtime-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
            if [[ -z "$latest" ]]; then
                latest="$_tag"
            else
                latest="$(printf '%s\n%s\n' "$latest" "$_tag" | sort -V | tail -n 1)"
            fi
        fi
    done <<< "$refs"
    if [[ -z "$latest" ]]; then
        echo "ERROR: no runtime-v[MAJOR].[MINOR].[PATCH] tags at $AIRPLANES_RUNTIME_REPO" >&2
        return 1
    fi
    printf '%s' "$latest"
}

# Returns the floating dev tag literally. Resolution to the underlying commit
# happens at download time when the release assets get fetched — the GitHub
# release referenced by this tag carries the matching `manifest.json`
# whose `version` field is cross-checked by airplanes_runtime_verify_manifest_version.
airplanes_runtime_resolve_dev_latest_tag() {
    printf '%s' "runtime-dev-latest"
}

# ---------------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------------
#
# A release is five files under
# https://github.com/airplanes-live/image/releases/download/<tag>/ :
#   <tag>-<arch>.tar.gz   — the per-arch payload (release dir tree)
#   manifest.json         — declares paths, migrations, etc.
#   SHA256SUMS            — sha256 over the above two files
#   SHA256SUMS.minisig    — minisign signature over SHA256SUMS
#   PROVENANCE.md         — build provenance, fetched but not verified by
#                           the on-device installer (operator triage only).
#
# Verification order: signature first (proves SHA256SUMS came from the
# signing key holder), then sha256sum -c on the data files (proves the
# tarball and manifest match what was signed). Any failure aborts.

airplanes_runtime_download_release() {
    local tag="$1" arch="$2" dest_dir="$3"
    local base="${AIRPLANES_RUNTIME_DOWNLOAD_BASE}/${tag}"
    local tarball_name="${tag}-${arch}.tar.gz"

    install -d -m 755 "$dest_dir"

    local f
    for f in "$tarball_name" "manifest.json" "SHA256SUMS" "SHA256SUMS.minisig" "PROVENANCE.md"; do
        if ! curl -fsSL --max-time 120 -o "$dest_dir/$f" "$base/$f"; then
            echo "ERROR: download failed: $base/$f" >&2
            return 1
        fi
    done

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

    # Filter SHA256SUMS to exactly the two files we want to verify (tarball
    # + manifest) so a SUMS file missing either line is caught loudly. The
    # signature file does not appear in its own SHA256SUMS — that's fine,
    # signature integrity is established by the minisign verify above.
    local filtered="$dest_dir/SHA256SUMS.expected"
    {
        grep -E "  ${tarball_name}\$" "$dest_dir/SHA256SUMS" || true
        grep -E "  manifest\.json\$"  "$dest_dir/SHA256SUMS" || true
    } > "$filtered"
    local expected_lines
    expected_lines="$(wc -l < "$filtered")"
    if [[ "$expected_lines" -ne 2 ]]; then
        echo "ERROR: SHA256SUMS missing one of $tarball_name / manifest.json" >&2
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
    # The release tag is `runtime-vX.Y.Z` or `runtime-dev-YYYYMMDD-<sha>` /
    # `runtime-dev-latest`; the manifest's `version` is `X.Y.Z` or
    # `X.Y.Z-dev-YYYYMMDD-<sha>` per the schema. Map one to the other.
    local expected_version="${expected_tag#runtime-}"   # strip "runtime-" prefix
    expected_version="${expected_version#v}"             # strip "v" if stable
    local got
    got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$manifest" 2>/dev/null || true)"
    if [[ -z "$got" ]]; then
        echo "ERROR: manifest.json missing version field (path: $manifest)" >&2
        return 1
    fi
    # The `runtime-dev-latest` floating tag has no version embedded in its
    # name; accept any dev-formatted version when the resolved tag was the
    # floating one. The immutable-tag variant carries an explicit version
    # and is checked exactly.
    if [[ "$expected_tag" == "runtime-dev-latest" ]]; then
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
    local path from owner perm src dst abs_dst tmp
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

    mv -Tf -- "$tmp" "$abs_dst"

    # post_install runs as a single sequential pipeline; abort on first
    # non-zero so a sudoers visudo -c failure surfaces immediately.
    local pi_count
    pi_count="$(jq -r ".managed_paths[$idx].post_install | length // 0" "$manifest")"
    if [[ "$pi_count" -gt 0 ]]; then
        local argv_json
        argv_json="$(jq -c ".managed_paths[$idx].post_install" "$manifest")"
        # Read into a bash array via mapfile + jq @sh would be safer if any
        # entry contained quotes; current schema's argvString minLength:1
        # combined with jq -r line-emission is sufficient for the v1
        # surface (visudo -c is the only declared post_install today).
        local -a argv=()
        local line
        while IFS= read -r line; do argv+=("$line"); done < <(jq -r '.[]' <<< "$argv_json")
        if ! "${argv[@]}"; then
            echo "ERROR: managed_paths[$idx] post_install failed: ${argv[*]}" >&2
            return 1
        fi
    fi
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
_airplanes_runtime_restart_order=(
    "readsb.service"
    "dump978-fa.service"
    "airplanes-978.service"
    "airplanes-tar1090-uat-sync.service"
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

airplanes_runtime_backup_mutable_path() {
    local release_dir="$1" target_root="$2" abs_path="$3"
    local preimage_dir="${release_dir}/.mutable-preimage"
    install -d -m 700 "$preimage_dir"
    local enc
    enc="$(_airplanes_runtime_encode_path "$abs_path")"
    # Write-once: if a preimage (or absent-marker) for this path already
    # exists, leave it alone. Otherwise a second backup pass — from
    # config_kv's per-migration preimage call running after the install
    # pipeline's batch backup — would clobber the true original with an
    # already-mutated intermediate state, leaving rollback unable to
    # restore the file to its pre-install content.
    if [[ -e "${preimage_dir}/${enc}" || -e "${preimage_dir}/${enc}.absent" ]]; then
        return 0
    fi
    local src="${target_root}${abs_path}"
    if [[ -e "$src" ]]; then
        cp -a -- "$src" "${preimage_dir}/${enc}"
    else
        # Mark "did not exist before this install" with a sentinel so
        # rollback knows to delete rather than restore.
        : > "${preimage_dir}/${enc}.absent"
    fi
}

airplanes_runtime_restore_mutable_path() {
    local release_dir="$1" target_root="$2" abs_path="$3"
    local preimage_dir="${release_dir}/.mutable-preimage"
    local enc
    enc="$(_airplanes_runtime_encode_path "$abs_path")"
    local dst="${target_root}${abs_path}"
    if [[ -f "${preimage_dir}/${enc}.absent" ]]; then
        rm -f -- "$dst"
        return 0
    fi
    if [[ -e "${preimage_dir}/${enc}" ]]; then
        install -d -m 755 "$(dirname "$dst")"
        cp -a -- "${preimage_dir}/${enc}" "$dst"
        return 0
    fi
    # No preimage and no absent-marker → nothing was backed up. Treat as
    # no-op rather than failing the whole rollback.
    return 0
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

# Runs every health gate, in declared order. Returns 0 only if every gate
# passes within its deadline. Caller handles rollback on non-zero return.
airplanes_runtime_run_health_gates() {
    local target_root="$1"
    local deadline="${AIRPLANES_RUNTIME_HEALTH_DEADLINE}"

    # readsb: aircraft.json fresh + tar1090 HTTP probe.
    local aircraft_json="${target_root}/run/readsb/aircraft.json"
    if ! _airplanes_runtime_probe_file_freshness "$aircraft_json" 30 "$deadline"; then
        return 1
    fi
    if ! _airplanes_runtime_probe_http_200 "${AIRPLANES_RUNTIME_PROBE_URL_BASE}/dump1090/data/aircraft.json" "$deadline"; then
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

airplanes_runtime_run_compat_preflight() {
    local manifest="$1" target_root="$2"

    if ! jq -e '.compat' "$manifest" >/dev/null 2>&1; then
        # No compat block declared → nothing to enforce.
        return 0
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
    ln -s -- "/opt/airplanes-runtime/current/manifest.json" "$tmp"
    mv -Tf -- "$tmp" "$link"
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

    if ! airplanes_runtime_is_build_mode; then
        airplanes_runtime_apply_systemd_ops "$manifest" || return 1
        airplanes_runtime_run_health_gates "$target_root" || return 1
        airplanes_runtime_record_runtime_manifest "$target_root" || return 1
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
    {
        printf 'state=%s\n'        "$new_state"
        printf 'prev_release=%s\n' "$prev_release"
        printf 'new_release=%s\n'  "$new_release"
        printf 'started_at=%s\n'   "$started_at"
        if [[ -n "$failure_reason" ]]; then
            printf 'failure_reason=%s\n' "$failure_reason"
        fi
    } > "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    # sync the file's data so a power-loss between mv and the rename
    # commit on ext4 still sees the staged content. Non-fatal if -d is
    # unsupported.
    sync -d "$tmp" 2>/dev/null || true
    mv -Tf -- "$tmp" "$f"
    sync -d "$(airplanes_runtime_state_dir "$target_root")" 2>/dev/null || true
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

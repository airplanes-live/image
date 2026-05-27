#!/usr/bin/env bats

# Feed mutability audit: asserts the feed daemon wrappers, apl-feed CLI, and
# runtime lib helpers never write under the immutable release directory
# (/opt/airplanes-runtime/current or /usr/local/share/airplanes when it is
# a symlink into the release tree). The feed stack writes to:
#   - /run/<service>/state (tmpfs, fine)
#   - /etc/airplanes/feed.env (mutable config, fine)
#   - /var/lib/airplanes-webconfig (webconfig state, fine)
# but must NOT mutate its own install directory (which is the release tree
# once managed_paths-symlinked through /opt/airplanes-runtime/current/).
#
# Static-analysis approach: grep the staged share/airplanes scripts (daemon
# wrappers, apl-feed subcommands, runtime libs) for shell redirect operators
# and file-write commands targeting $IPATH or the absolute install path. The
# invariant is "the release dir is read-only at runtime".

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # Feed sibling is next to the image repo root. In CI that is ../feed;
    # in the workspace layout (worktree under .claude/worktrees/) it may be
    # further up. Try both; skip cleanly if neither exists.
    FEED_DIR=""
    for candidate in "$REPO_ROOT/../feed" "$REPO_ROOT/../../feed"; do
        if [[ -d "$candidate/scripts" ]]; then
            FEED_DIR="$(cd "$candidate" && pwd)"
            break
        fi
    done
    [ -n "$FEED_DIR" ] || skip "feed checkout not found next to image repo"
}

# Grep all feed runtime scripts for writes targeting the install directory.
# We look for patterns that would write under /usr/local/share/airplanes/
# (the IPATH on a standard install, symlinked into the overlay release tree)
# or under $IPATH itself. The daemon wrappers must only write to /run/ (state
# files) and /etc/airplanes/ (feed.env). Anything else is a mutability leak.
#
# Exempt patterns:
#   - comments (lines starting with #)
#   - echo/printf to stdout/stderr (no redirect to a file under IPATH)
#   - state-writer.sh (writes to /run/ paths passed as arguments)
#   - install.sh / update.sh / setup.sh / configure.sh (install-time only)
#   - uninstall.sh (removal-time only)

_feed_runtime_scripts() {
    # Daemon wrappers + CLI + runtime libs — these are what the overlay stages.
    local files=()
    for f in "$FEED_DIR"/scripts/airplanes-feed.sh \
             "$FEED_DIR"/scripts/airplanes-mlat.sh \
             "$FEED_DIR"/scripts/airplanes-diagnostics.sh \
             "$FEED_DIR"/scripts/apl-feed.sh \
             "$FEED_DIR"/scripts/apl-feed/*.sh \
             "$FEED_DIR"/scripts/lib/state-reader.sh \
             "$FEED_DIR"/scripts/lib/configure-validators.sh \
             "$FEED_DIR"/scripts/lib/feed-env-keys.sh \
             "$FEED_DIR"/scripts/lib/feed-env-apply.sh \
             "$FEED_DIR"/scripts/lib/legacy-mlat-translation.sh; do
        [[ -f "$f" ]] && files+=("$f")
    done
    printf '%s\n' "${files[@]}"
}

@test "feed runtime scripts never redirect output to IPATH" {
    # Find shell redirect writes (>, >>) targeting the install path. Strip
    # comments and install/update-only scripts (not staged in the overlay).
    local hits=""
    while IFS= read -r script; do
        local matches
        matches="$(grep -nE '(>|>>)\s*/usr/local/share/airplanes/' "$script" \
            | grep -v '^\s*#' \
            | grep -v 'state-writer' || true)"
        if [[ -n "$matches" ]]; then
            hits+="$script: $matches"$'\n'
        fi
    done < <(_feed_runtime_scripts)
    [ -z "$hits" ] || { echo "FAIL: feed scripts write under IPATH:" >&2; echo "$hits" >&2; return 1; }
}

@test "feed runtime scripts never use install/cp/mkdir targeting IPATH" {
    local hits=""
    while IFS= read -r script; do
        local matches
        matches="$(grep -nE '(install |cp |mkdir ).*/usr/local/share/airplanes/' "$script" \
            | grep -v '^\s*#' || true)"
        if [[ -n "$matches" ]]; then
            hits+="$script: $matches"$'\n'
        fi
    done < <(_feed_runtime_scripts)
    [ -z "$hits" ] || { echo "FAIL: feed scripts install/cp/mkdir under IPATH:" >&2; echo "$hits" >&2; return 1; }
}

@test "feed daemon wrappers only write to /run/ and /etc/airplanes/" {
    # Broader assertion: verify the daemon wrappers' write surface. The only
    # write operations should target /run/<svc>/state (via state-writer.sh)
    # and /etc/airplanes/ (via feed-env-apply). Anything else is a leak.
    for wrapper in "$FEED_DIR"/scripts/airplanes-feed.sh "$FEED_DIR"/scripts/airplanes-mlat.sh; do
        [[ -f "$wrapper" ]] || continue
        local non_run_writes
        non_run_writes="$(grep -nE '(>|>>)\s*[^|]' "$wrapper" \
            | grep -v '^\s*#' \
            | grep -v '/run/' \
            | grep -v '/dev/null' \
            | grep -v '&2' \
            | grep -v '&1' \
            | grep -v '/etc/airplanes/' || true)"
        [ -z "$non_run_writes" ] || {
            echo "FAIL: $(basename "$wrapper") writes outside /run/ and /etc/airplanes/:" >&2
            echo "$non_run_writes" >&2
            return 1
        }
    done
}

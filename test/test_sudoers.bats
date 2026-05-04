#!/usr/bin/env bats

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    SUDOERS="$REPO_ROOT/stage-airplanes/05-install-webconfig/files/etc/sudoers.d/010_airplanes-webconfig"
}

@test "sudoers file exists" {
    [ -f "$SUDOERS" ]
}

@test "visudo -cf accepts the sudoers snippet" {
    # Stage a copy at 0440 so visudo's mode check is happy even though the
    # source-tree copy is 0644 (chroot install lowers it).
    local tmp
    tmp="$(mktemp)"
    install -m 0440 "$SUDOERS" "$tmp"
    run visudo -cf "$tmp"
    rm -f "$tmp"
    [ "$status" -eq 0 ]
}

@test "every non-comment line specifies fixed argv via NOPASSWD" {
    # Strip comments + blanks, then assert each remaining line matches the
    # expected shape. Wildcards (*), env passthrough (SETENV), or omission
    # of NOPASSWD would fail.
    local line
    while IFS= read -r line; do
        if ! [[ "$line" =~ NOPASSWD: ]]; then
            echo "missing NOPASSWD: in $line"
            return 1
        fi
        if [[ "$line" =~ \* ]]; then
            echo "wildcard found in $line"
            return 1
        fi
        if [[ "$line" =~ SETENV ]]; then
            echo "SETENV found in $line"
            return 1
        fi
    done < <(grep -E -v '^\s*(#|$)' "$SUDOERS")
}

@test "user is airplanes-webconfig on every line" {
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^airplanes-webconfig[[:space:]] ]] || {
            echo "non-airplanes-webconfig user in: $line"
            return 1
        }
    done < <(grep -E -v '^\s*(#|$)' "$SUDOERS")
}

#!/usr/bin/env bash
# Emits a canonical fingerprint of webconfig-owned artifacts to stdout, one
# line per artifact, sorted. Used by update-regression-inner.sh to detect
# drift caused by feed/update.sh runs.
#
# Output format (one of):
#   user_NAME uid=N gid=N groups=g1,g2,...
#   user_NAME MISSING
#   group_NAME gid=N
#   group_NAME MISSING
#   type=f mode=NNNN uid=N gid=N user=NAME group=NAME sha256=HASH path=/...
#   type=l mode=NNNN uid=N gid=N user=NAME group=NAME target=PATH path=/...
#   type=d mode=NNNN uid=N gid=N user=NAME group=NAME path=/...
#   type=X MISSING path=/...
#   type=X WRONG_TYPE path=/...
#
# Symlink target is captured verbatim (readlink), not resolved — the link
# itself is what stage 05 owns.

WEBCONFIG_USERS=(airplanes-webconfig airplanes-feed)
WEBCONFIG_GROUPS=(airplanes-webconfig airplanes-feed)

WEBCONFIG_REGULAR_FILES=(
    /etc/sudoers
    /etc/sudoers.d/010_airplanes-webconfig
    /etc/systemd/system/airplanes-webconfig.service
    /etc/systemd/system/airplanes-webconfig-reset.service
    /etc/lighttpd/conf-available/40-airplanes-webconfig.conf
    /usr/lib/tmpfiles.d/airplanes-webconfig.conf
    /usr/local/bin/airplanes-webconfig
    /opt/airplanes/current/lib/airplanes-webconfig/reset
    /opt/airplanes/current/share/airplanes/update.sh
    /etc/airplanes/feed.env
    /var/lib/airplanes/webconfig/.update-regression-sentinel
    /etc/airplanes/webconfig/.update-regression-sentinel
)

WEBCONFIG_SYMLINKS=(
    /etc/lighttpd/conf-enabled/40-airplanes-webconfig.conf
    /etc/lighttpd/conf-enabled/10-proxy.conf
    /etc/systemd/system/airplanes-webconfig.service.wants/airplanes-webconfig-reset.service
    /etc/systemd/system/multi-user.target.wants/airplanes-webconfig.service
)

WEBCONFIG_DIRS=(
    /etc/airplanes
    /etc/airplanes/webconfig
    /etc/sudoers.d
    /var/lib/airplanes/webconfig
    /opt/airplanes/current/lib/airplanes-webconfig
)

# Dirs whose contents are recursively fingerprinted to catch unexpected
# files added by update.sh beyond the explicit lists above.
WEBCONFIG_RECURSIVE_DIRS=(
    /var/lib/airplanes/webconfig
    /etc/airplanes/webconfig
    /etc/sudoers.d
    /opt/airplanes/current/lib/airplanes-webconfig
)

webconfig_fingerprint() {
    local name path entry known skip
    {
        for name in "${WEBCONFIG_USERS[@]}"; do
            _wc_fingerprint_user "$name"
        done
        for name in "${WEBCONFIG_GROUPS[@]}"; do
            _wc_fingerprint_group "$name"
        done
        for path in "${WEBCONFIG_REGULAR_FILES[@]}"; do
            _wc_fingerprint_file "$path"
        done
        for path in "${WEBCONFIG_SYMLINKS[@]}"; do
            _wc_fingerprint_symlink "$path"
        done
        for path in "${WEBCONFIG_DIRS[@]}"; do
            _wc_fingerprint_dir "$path"
        done
        for path in "${WEBCONFIG_RECURSIVE_DIRS[@]}"; do
            [[ -d "$path" ]] || continue
            while IFS= read -r -d '' entry; do
                skip=0
                for known in "${WEBCONFIG_REGULAR_FILES[@]}" \
                             "${WEBCONFIG_SYMLINKS[@]}" \
                             "${WEBCONFIG_DIRS[@]}"; do
                    if [[ "$entry" == "$known" ]]; then
                        skip=1
                        break
                    fi
                done
                [[ "$skip" == 1 ]] && continue
                _wc_fingerprint_auto "$entry"
            done < <(find "$path" -mindepth 1 -print0 2>/dev/null)
        done
    } | LC_ALL=C sort
}

_wc_fingerprint_user() {
    local name="$1" uid gid groups
    if ! getent passwd "$name" >/dev/null; then
        printf 'user_%s MISSING\n' "$name"
        return
    fi
    uid=$(id -u "$name")
    gid=$(id -g "$name")
    groups=$(id -nG "$name" | tr ' ' '\n' | LC_ALL=C sort -u | paste -sd, -)
    printf 'user_%s uid=%d gid=%d groups=%s\n' "$name" "$uid" "$gid" "$groups"
}

_wc_fingerprint_group() {
    local name="$1" gid
    if ! getent group "$name" >/dev/null; then
        printf 'group_%s MISSING\n' "$name"
        return
    fi
    gid=$(getent group "$name" | cut -d: -f3)
    printf 'group_%s gid=%d\n' "$name" "$gid"
}

_wc_fingerprint_file() {
    local p="$1" mode uid gid user group sha
    if [[ -L "$p" ]]; then
        # Expected regular file; got a symlink. Surface as drift.
        _wc_fingerprint_symlink "$p"
        return
    fi
    if [[ ! -e "$p" ]]; then
        printf 'type=f MISSING path=%s\n' "$p"
        return
    fi
    if [[ ! -f "$p" ]]; then
        printf 'type=f WRONG_TYPE path=%s\n' "$p"
        return
    fi
    mode=$(stat -c '%a' "$p")
    uid=$(stat -c '%u' "$p")
    gid=$(stat -c '%g' "$p")
    user=$(stat -c '%U' "$p")
    group=$(stat -c '%G' "$p")
    if ! sha=$(sha256sum "$p" 2>/dev/null | cut -d' ' -f1) || [[ -z "$sha" ]]; then
        printf 'type=f READ_ERROR mode=%s uid=%d gid=%d user=%s group=%s path=%s\n' \
            "$mode" "$uid" "$gid" "$user" "$group" "$p"
        return
    fi
    printf 'type=f mode=%s uid=%d gid=%d user=%s group=%s sha256=%s path=%s\n' \
        "$mode" "$uid" "$gid" "$user" "$group" "$sha" "$p"
}

_wc_fingerprint_symlink() {
    local p="$1" mode uid gid user group target
    if [[ ! -e "$p" && ! -L "$p" ]]; then
        printf 'type=l MISSING path=%s\n' "$p"
        return
    fi
    if [[ ! -L "$p" ]]; then
        printf 'type=l WRONG_TYPE path=%s\n' "$p"
        return
    fi
    mode=$(stat -c '%a' "$p")
    uid=$(stat -c '%u' "$p")
    gid=$(stat -c '%g' "$p")
    user=$(stat -c '%U' "$p")
    group=$(stat -c '%G' "$p")
    target=$(readlink "$p")
    printf 'type=l mode=%s uid=%d gid=%d user=%s group=%s target=%s path=%s\n' \
        "$mode" "$uid" "$gid" "$user" "$group" "$target" "$p"
}

_wc_fingerprint_dir() {
    local p="$1" mode uid gid user group
    if [[ ! -e "$p" ]]; then
        printf 'type=d MISSING path=%s\n' "$p"
        return
    fi
    if [[ ! -d "$p" || -L "$p" ]]; then
        printf 'type=d WRONG_TYPE path=%s\n' "$p"
        return
    fi
    mode=$(stat -c '%a' "$p")
    uid=$(stat -c '%u' "$p")
    gid=$(stat -c '%g' "$p")
    user=$(stat -c '%U' "$p")
    group=$(stat -c '%G' "$p")
    printf 'type=d mode=%s uid=%d gid=%d user=%s group=%s path=%s\n' \
        "$mode" "$uid" "$gid" "$user" "$group" "$p"
}

_wc_fingerprint_auto() {
    local p="$1"
    if [[ -L "$p" ]]; then
        _wc_fingerprint_symlink "$p"
    elif [[ -f "$p" ]]; then
        _wc_fingerprint_file "$p"
    elif [[ -d "$p" ]]; then
        _wc_fingerprint_dir "$p"
    else
        printf 'type=? UNKNOWN path=%s\n' "$p"
    fi
}

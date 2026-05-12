# 06b-console-dashboard

Adds an ASCII-art status dashboard on `/dev/tty1` (refreshes every 5s)
and the same dashboard as a one-shot snapshot at SSH login (via
`update-motd.d`). Local console login moves to TTY2 (Alt+F2).

The dashboard service is wired to `multi-user.target` and waits a brief
grace period (`ExecStartPre=/bin/sleep 6`) before starting, so boot
output finishes scrolling on TTY1 first and the dashboard takes over on
a clean screen. A best-effort `setterm --msg off` then silences kernel
printk-on-VT for `/dev/tty1` only (serial console on `serial0,115200` is
unaffected) so late USB/rfkill kmsg can't bleed into the live display.

The live-render loop is double-buffered: each frame is rendered to a
tmpfile first, then the dispatcher repaints in place — cursor home,
each line followed by `\e[K` (erase to end of line so a shorter new
line clears trailing chars from the previous frame), then `\e[J` at the
end (erase any leftover rows below if the new frame is shorter). The
screen is never blanked between frames, so the gather window
(`timeout 2 systemctl show …` for the five tracked units, plus the
nmcli and aircraft.json reads) elapses with the previous frame still
visible. The caret is hidden for the lifetime of the loop
(`\e[?25l` … `\e[?25h`) so the in-flight per-line writes don't show a
stepping cursor. A single batched `systemctl show -p Id -p ActiveState
-p UnitFileState -p ExecMainStatus` primes a per-frame cache that all
the unit-state helpers read from, so the frame's dbus budget is one
`timeout 2` call instead of ~12.

The chroot stage also strips Debian / Raspberry Pi OS defaults that
`pam_motd` would otherwise print at TTY2/SSH login: `/etc/motd` is reset
to an empty file and the upstream `update-motd.d` hooks (`10-uname`,
`00-header`, `10-help-text`, `50-motd-news`) are removed. Only
`10-airplanes-status` runs, so login output is the dashboard and nothing
else (besides sshd's own `Last login:` line, which is out of scope).

## What lands in the rootfs

- `/usr/local/lib/airplanes/render-status` — bash renderer with three
  modes: `--snapshot` (one-shot, no clear; used by the MOTD hook),
  `--live` (loop, double-buffered repaint every 5s; used by the systemd
  unit), `--once` (one-shot with screen clear).
- `/usr/local/share/airplanes/logo.txt` — 40×22 plane-badge artwork
  used as the last-resort `--live` fallback when even the narrow banner
  won't fit.
- `/usr/local/share/airplanes/banner.txt` — 135×20 banner artwork
  (badge + "airplanes.live" wordmark) used at the top of the HDMI
  dashboard on wide displays.
- `/usr/local/share/airplanes/banner-narrow.txt` — 74×11 compact
  banner (badge + "airplanes.live" wordmark) used at the top of the
  HDMI dashboard when the framebuffer console is too narrow for the
  wide banner. Fits any ≥720p HDMI output at the default 8×16 kernel
  console font.
- `/usr/local/share/airplanes/icon.txt` — 20×11 small ASCII airplane
  badge used by the snapshot (SSH MOTD / `--once`) layout. Renders to
  the left of a 3-line text header (airplanes.live / random tagline /
  feed version) above the compact status panel. The text header takes
  prime real estate from the version line, so the compact panel no
  longer prints a standalone "Build channel=… sha=…" row.
- `/etc/systemd/system/airplanes-dashboard.service` — owns `/dev/tty1`,
  `Conflicts=getty@tty1.service`, `WantedBy=multi-user.target`.
- `/etc/systemd/system/getty@tty1.service.d/override.conf` —
  defense-in-depth `Conflicts=airplanes-dashboard.service` if the mask is
  later cleared.
- `/etc/update-motd.d/10-airplanes-status` — wraps the renderer with
  `--snapshot`. Runs as root via `pam_motd` (post-auth on SSH and TTY2).

## What the chroot step does

`01-run-chroot.sh` runs four `systemctl` calls (all `enable`/`disable`/
`mask` — no lifecycle verbs, so `check-stub-log.sh`'s `FORBIDDEN_RE` is
not tripped):

1. `disable getty@tty1.service` — removes stale `getty.target.wants/`
   symlink if any.
2. `mask getty@tty1.service` — symlinks the unit to `/dev/null` so
   `systemd-getty-generator` cannot resurrect it from the kernel cmdline
   `console=tty1`.
3. `enable getty@tty2.service` — local login moves here. (The generator
   only auto-instantiates tty1; tty2 needs explicit enable.)
4. `enable airplanes-dashboard.service` — the dashboard.

`serial-getty@serial0.service` is **untouched** — `console=serial0,115200`
is still on the kernel cmdline, so a UART recovery login remains
available.

## Layout dispatch

The renderer picks a layout based on mode and a runtime width guard so
under-sized terminals degrade rather than wrap:

| Mode         | ≥ 135 cols                            | ≥ 74 cols                                       | ≥ 60 cols                                       | < threshold                              |
|--------------|---------------------------------------|-------------------------------------------------|-------------------------------------------------|------------------------------------------|
| `--live`     | wide `banner.txt` (135 cols) on top, full status below | `banner-narrow.txt` (74 cols) on top, full status below | —                                               | small `logo.txt` (40 cols) on top, full status below |
| `--snapshot` | —                                     | —                                               | `icon.txt` (20 cols) on the left, 3-line text header + compact status panel on the right | text-only header + compact status, no icon |
| `--once`     | same as `--snapshot`                  | same as `--snapshot`                            | same as `--snapshot`                            | same as `--snapshot`                     |

`term_cols()` reports `tput cols` when stdout is a TTY and `TERM` is
set, else 80. The update-motd.d hook is captured by `pam_motd` (no TTY
on stdout), so it deterministically uses the 80-col path. The
`airplanes-dashboard.service` unit sets `Environment=TERM=linux` so the
TTY1 renderer can actually measure the framebuffer console width
(systemd services start with no `TERM` by default, which would make
`tput` fail the terminfo lookup and force a permanent 80-col fallback).

If an artwork file fails to load (missing, CRLF, or wrong width), the
`--live` dispatcher walks the chain `banner.txt → banner-narrow.txt →
logo.txt → no-art` so a missing or malformed file never breaks the
dashboard.

## Charset note

The shipped artwork uses Unicode block characters (`█▓▒░`). Any modern
terminal (HDMI framebuffer console, all common SSH clients, recent
serial-emulator clients) renders these as expected. A serial-recovery
session on a non-UTF-8 locale will see replacement glyphs in place of
the block art — cosmetic only; the status block remains plain ASCII
and fully readable.

## Artwork regeneration

The committed `logo.txt` and `banner.txt` were rendered from
`https://www.airplanes.live/img/airplanes-live-logo.png` (1029×287 PNG)
with `chafa` and hand-trimmed. `banner-narrow.txt` was hand-built from
the same source. `icon.txt` is a 20×11 hand-trimmed ASCII rendition of
the same logo, sized to sit next to the 3-line snapshot text header
without dominating it. All four files are shipped verbatim — no
runtime image-conversion dependency.

To regenerate when the upstream logo changes:

```sh
curl -L -o /tmp/aplogo.png \
    https://www.airplanes.live/img/airplanes-live-logo.png

# logo.txt — 40 cols × 22 rows, badge only (the side-by-side panel
# already prints "airplanes.live" in its status section, so the small
# logo doesn't need the wordmark).
chafa --symbols=block --bg=none --size=40x22 \
    /tmp/aplogo.png \
    > files/usr/local/share/airplanes/logo.txt

# banner.txt — 135 cols × 20 rows, badge + wordmark (the HDMI dashboard
# has the headroom; it's the user's first impression on boot).
chafa --symbols=block --bg=none --size=135x20 \
    /tmp/aplogo.png \
    > files/usr/local/share/airplanes/banner.txt

# banner-narrow.txt — 74 cols × 11 rows, badge + wordmark sized to fit
# any ≥720p HDMI output at the default 8×16 kernel console font.
# Hand-trimmed; chafa's --size output usually needs manual cleanup at
# this aspect ratio.
```

Constraints, enforced by `load_artwork` in the renderer:

- Each line in `logo.txt` is exactly **40 display columns** wide; the
  file has at least one line.
- Each line in `banner.txt` is exactly **135 display columns** wide;
  the file has at least one line.
- Each line in `banner-narrow.txt` is exactly **74 display columns**
  wide; the file has at least one line.
- Each line in `icon.txt` is exactly **20 display columns** wide; the
  file has at least one line.
- No CRLF (LF only).
- Trailing whitespace **must be preserved** so each line is padded to
  the expected width — do **not** run `sed 's/[[:space:]]*$//'`.

If a regenerated file violates any of these, the renderer falls back
silently (banner → narrow banner → logo → no-art) so the dashboard
keeps rendering.

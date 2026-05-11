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
  used in the SSH/TTY2 side-by-side layout (and as the narrow-terminal
  fallback for `--live`).
- `/usr/local/share/airplanes/banner.txt` — 135×20 banner artwork
  (badge + "airplanes.live" wordmark) used at the top of the HDMI
  dashboard.
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

The renderer picks one of two layouts based on mode, with a runtime
width guard so under-sized terminals degrade rather than wrap:

| Mode         | Wide enough                          | Narrow fallback                        |
|--------------|--------------------------------------|----------------------------------------|
| `--live`     | banner (`banner.txt`, 135 cols) on top, full status below (≥ 135 cols) | small logo on top, full status below (< 135 cols) |
| `--snapshot` | logo (`logo.txt`, 40 cols) on the left, 38-col compact status panel on the right (≥ 80 cols) | compact status only, no logo (< 80 cols) |
| `--once`     | same as `--snapshot`                 | same as `--snapshot`                   |

`term_cols()` reports `tput cols` when stdout is a TTY, else 80. The
update-motd.d hook is captured by `pam_motd` (no TTY on stdout), so it
deterministically uses the 80-col path.

If `banner.txt` fails to load (missing, CRLF, or wrong width),
`--live` falls back to the small logo. If `logo.txt` also fails, the
art is skipped and only the status block prints.

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
with `chafa` and hand-trimmed. Both files are shipped verbatim — no
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
```

Constraints, enforced by `load_artwork` in the renderer:

- Each line in `logo.txt` is exactly **40 display columns** wide; the
  file has at least one line.
- Each line in `banner.txt` is exactly **135 display columns** wide;
  the file has at least one line.
- No CRLF (LF only).
- Trailing whitespace **must be preserved** so each line is padded to
  the expected width — do **not** run `sed 's/[[:space:]]*$//'`.

If a regenerated file violates any of these, the renderer falls back
silently (banner→logo→no-art) so SSH login is never broken.

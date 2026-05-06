# 06b-console-dashboard

Adds an ASCII-logo + status dashboard on `/dev/tty1` (refreshes every 5s)
and the same dashboard as a one-shot snapshot at SSH login (via
`update-motd.d`). Local console login moves to TTY2 (Alt+F2).

The dashboard service is wired to `multi-user.target` and waits a brief
grace period (`ExecStartPre=/bin/sleep 6`) before starting, so boot
output finishes scrolling on TTY1 first and the dashboard takes over on
a clean screen. A best-effort `setterm --msg off` then silences kernel
printk-on-VT for `/dev/tty1` only (serial console on `serial0,115200` is
unaffected) so late USB/rfkill kmsg can't bleed into the live display.

The live-render loop emits a full clear (`\e[H\e[J`) before every frame
so dashboard fields that get shorter between frames don't leave stale
trailing characters on screen.

The chroot stage also strips Debian / Raspberry Pi OS defaults that
`pam_motd` would otherwise print at TTY2/SSH login: `/etc/motd` is reset
to an empty file and the upstream `update-motd.d` hooks (`10-uname`,
`00-header`, `10-help-text`, `50-motd-news`) are removed. Only
`10-airplanes-status` runs, so login output is the dashboard and nothing
else (besides sshd's own `Last login:` line, which is out of scope).

## What lands in the rootfs

- `/usr/local/lib/airplanes/render-status` — bash renderer with three
  modes: `--snapshot` (one-shot, no clear; used by the MOTD hook),
  `--live` (loop with home-cursor + erase-to-end every 5s; used by the
  systemd unit), `--once` (one-shot with screen clear).
- `/usr/local/share/airplanes/logo.txt` — pre-rendered ASCII logo.
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

## Logo regeneration

The committed `logo.txt` was generated from
`https://www.airplanes.live/img/airplanes-live-logo.png` (1029×287 PNG).
There is no runtime image-conversion dependency; the file is shipped
verbatim.

To regenerate when the upstream logo changes:

```sh
# On a workstation with chafa or imagemagick + python3-pil:
curl -L -o /tmp/aplogo.png \
    https://www.airplanes.live/img/airplanes-live-logo.png

# Option A — chafa (preferred when available):
chafa --symbols=ascii --colors=2 --bg=none --fg=blue --size=78x10 \
    /tmp/aplogo.png \
    > files/usr/local/share/airplanes/logo.txt

# Option B — python3-pil with the contrast-boosted ramp used at first cut:
python3 - <<'PY' > files/usr/local/share/airplanes/logo.txt
from PIL import Image, ImageEnhance, ImageOps
img = Image.open('/tmp/aplogo.png').convert('L')
img = ImageOps.autocontrast(img, cutoff=5)
img = ImageEnhance.Contrast(img).enhance(1.5)
W, H = img.size
target_w = 78
target_h = max(1, round(H * target_w / W / 2.1))
img = img.resize((target_w, target_h), Image.LANCZOS)
ramp = ' .:-=+*#%@'
out = []
for y in range(target_h):
    out.append(''.join(
        ramp[min(len(ramp)-1, int((255 - img.getpixel((x, y))) * len(ramp) / 256))]
        for x in range(target_w)
    ).rstrip())
while out and not out[0].strip(): out.pop(0)
while out and not out[-1].strip(): out.pop()
print('\n'.join(out))
PY

sed -i 's/[[:space:]]*$//' files/usr/local/share/airplanes/logo.txt
```

Hand-trim if the auto-render is ugly. Constraints: ≤ 80 cols, ≤ 12 rows,
plain ASCII (no Unicode block chars — survives serial UART users with
non-UTF-8 locales).

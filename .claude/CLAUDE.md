# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A pi-gen fork that produces flashable Raspberry Pi OS images for ADS-B feeder hardware. The build runs the upstream pi-gen stages (`stage0`, `stage1`, `stage2`) plus a fork-specific `stage-airplanes/` that installs the decoder, the feed daemon, the web UI, the first-boot config script, and the console dashboard. Two channels: `config-dev` (tracks branch refs) and `config-stable` (pinned SHAs).

## Build

Local build (requires root):

```
sudo -E ./build.sh -c config-dev      # or: -c config-stable
```

Docker-wrapped build (handles qemu / binfmt for cross-arch on non-arm64 hosts):

```
./build-docker.sh -c config-dev
```

Both produce a compressed image at `deploy/airplanes-feeder-{dev|stable}-arm64.img.xz`. The Docker wrapper also fixes artifact ownership on exit. Build dependencies are listed in `depends`; the `Dockerfile` apt-installs them inside a Debian trixie image.

## Test & lint

CI (`.github/workflows/ci.yml`) runs on push to `main`/`dev` and on PRs:

| Job | What it does |
|---|---|
| `shell-lint` | shellcheck + `bash -n` over stage and test scripts |
| `shell-tests` | `bats test/` — first-run parsing, WiFi config, hostname handling, FEED_HOST override, webconfig manifest, render-status, sudoers, systemctl stubs |
| `feed-overlay-smoke` | Checks out `airplanes-live/feed` `dev`, mounts the built image, runs `test/overlay-smoke.sh` integration |
| `webconfig-test` | `go vet` + `go mod verify` + unit tests for `webconfig/` |
| `webconfig-cross-build` | `webconfig` cross-compile (matrix `webconfig-cross-build-arm64`, `webconfig-cross-build-armhf`) |
| `systemd-verify` | `systemd-analyze verify` against all `.service` files (with stubbed binaries and fetched upstream tar1090 / graphs1090 units) |
| `feed-update-regression` | Checks out feed `dev`, runs `test/update-regression-smoke.sh` |

Image builds run separately via `.github/workflows/build-image.yml` on `ubuntu-24.04-arm` (native arm64, no qemu) with per-channel artifact retention plus per-cell rootfs and first-run chroot smoke validation.

Run a single bats file locally:

```
bats test/test_first_run_basic.bats
```

`.shellcheckrc` disables `SC1091` (sourced-file resolution) for config files. There is no `.gitlab-ci.yml` workflow of substance — the file is a 70-byte include of upstream pi-gen's CI.

## Architecture

### Stage layout

```
stage0  stage1  stage2          ← upstream pi-gen (base OS, boot files, networking)
stage-airplanes/                 ← fork-specific
  00-prep                        build deps + chroot hygiene (policy-rc.d, systemctl shim) + SSH posture + cloud-init/first-boot-wizard mask
  01-install-feed                clones airplanes-live/feed, installs apl-feed
  02-install-decoder             builds readsb + dump978
  03-install-tar1090             tar1090 + tar1090-db
  04-install-graphs1090          graphs1090
  05-install-webconfig           Go webconfig (cross-compiled for arm64 + armhf)
  06-firstboot                   airplanes-first-run script + claim service/timer + boot config template
  06b-console-dashboard          ASCII dashboard renderer + tty1 service
  07-finalize                    boot perms, build artifact cleanup
export-image / export-noobs      pi-gen finalization (compresses rootfs into .img and optional NOOBS archive)
```

Each substage has `00-run.sh` (host-side: clone, copy files into rootfs) and/or `01-run-chroot.sh` (chroot-side: apt, systemctl, unit configuration).

### First-boot flow

Pi boots → cloud-init runs (handles user-data / WiFi / hostname injected by rpi-imager) → `airplanes-first-run.service` runs every boot, gated by file presence rather than a rootfs marker. If `/boot/firmware/airplanes-config.txt` exists: parse + apply (HOSTNAME / WiFi keyfile / FEED_HOST translations + feed.env merge), then **rename source → `airplanes-config.applied.txt`** on full success, or write a sibling `airplanes-config.error.txt` and leave the source for retry on failure. → `airplanes-feed.service` connects to `feed.airplanes.live` → `airplanes-claim.timer` periodically polls the claim endpoint until claimed. cloud-init does not read `airplanes-config.txt`; that file is exclusively `airplanes-first-run`'s input.

The state machine on FAT visible to a user pulling the SD card: `airplanes-config.txt` only = pending or failed; `airplanes-config.txt` + `airplanes-config.error.txt` = failed (read .error.txt to see what to fix); `airplanes-config.applied.txt` only = consumed successfully. The unit is sandboxed with `ProtectSystem=true` + `ReadWritePaths=/boot/firmware /usr/local/share/airplanes` + `RuntimeDirectory=airplanes` — chroot tests bypass that sandbox, so a static lint at `test/test_first_run_unit.bats` asserts the directives stay aligned with what the script actually writes.

`airplanes-config.txt` keys: `LATITUDE`, `LONGITUDE`, `ALTITUDE`, `MLAT_USER`, `MLAT_ENABLED`, `UAT_INPUT`, `HOSTNAME`, `WIFI_SSID`, `WIFI_PASS`, `WIFI_COUNTRY`, `FEED_HOST`, `MLATSERVER`, `TARGET`. Once boot finishes, the web UI at `http://<hostname>.local/` becomes the canonical config interface (writes to `feed.env`, restarts services). See `stage-airplanes/06-firstboot/README.md` for the parser detail.

### Console dashboard

`airplanes-dashboard.service` owns `/dev/tty1` (HDMI) and conflicts with `getty@tty1` (masked). Renders a full-screen ASCII status every 5s via `render-status` (`stage-airplanes/06b-console-dashboard/files/usr/local/lib/airplanes/render-status`). SSH login shows the same snapshot via `/etc/update-motd.d/10-airplanes-status`. TTY2 (Alt+F2) is the fallback local console. Modes: `--snapshot`, `--live`, `--once`. Layout adapts wide vs narrow. Artwork constraints + regeneration via `chafa` are documented in `stage-airplanes/06b-console-dashboard/README.md`.

### Web UI

Go server in `webconfig/` (modules: `auth`, `feedenv`, `identity`, `logs`, `server`, `status`). Built into `/usr/local/bin/airplanes-webconfig` listening on `127.0.0.1:8080`. Reverse-proxied by lighttpd on `:80`. State source of truth is `/etc/airplanes/feed.env` plus the daemon runtime state files at `/run/<service>/state` (the daemons publish; the UI reads).

## Channels

| | `config-dev` | `config-stable` |
|---|---|---|
| `IMG_NAME` | `airplanes-feeder-dev-arm64` | `airplanes-feeder-stable-arm64` |
| Component refs | branches (`dev` / `master`) | pinned SHAs for feed, readsb, readsb-decoder, dump978, tar1090, tar1090-db, graphs1090 |
| Compression | `xz -1` (fast rebuild) | `xz -6` (small artifact) |
| `ENABLE_SSH` | `1` | `1` |

Both export via `export-image/`. Stable images are reproducible from the pinned SHAs; dev images are intentionally not.

## Cross-repo coupling with `airplanes-live/feed`

The boot config schema in `/boot/firmware/airplanes-config.txt` (notably `MLAT_USER` + `MLAT_ENABLED` + `UAT_INPUT`), the `airplanes-first-run.service` ordering, and the daemon runtime state-file pattern at `/run/<service>/state` are coordinated with `airplanes-live/feed`. The image-shipped 978 wrappers (`airplanes-978.sh`, `dump978-fa.sh`) read `UAT_INPUT` from feed.env and publish their decision via `state-writer.sh` from `/usr/local/share/airplanes/lib/` (a feed-installed library), so the contract is symmetric with airplanes-feed and airplanes-mlat. Concretely:

- `stage-airplanes/01-install-feed/` clones `airplanes-live/feed` at the ref pinned in `config-{dev,stable}` and installs `apl-feed` plus systemd units.
- `stage-airplanes/06-firstboot/00-run.sh` writes `/etc/airplanes/release-channel` (read by `feed/update.sh`'s allowlist for `AIRPLANES_FEED_BRANCH`).
- CI's `feed-overlay-smoke` and `feed-update-regression` jobs check out feed `dev` and exercise its smoke scripts (`test/image-release-rootfs-smoke.sh`, `test/update-regression-smoke.sh`) against the built image.

Changes to the boot config schema, the `airplanes-first-run` parser, or the unit ordering need a paired feed PR (typically against `feed/dev`); see `feed/.claude/rules/architecture.md` for the daemon-side contract — the daemons own the `/run/<service>/state` format and the `MLAT_ENABLED`-before-geo classifier.

## Migration & legacy

`README.md` covers the user-facing migration path from the legacy airplanes.live image (per-feeder UUID handover, claim flow). `README-advanced.md` covers pointing the feeder at non-production backends via `FEED_HOST` / `MLATSERVER` / `TARGET` env overrides — useful for staging environments.

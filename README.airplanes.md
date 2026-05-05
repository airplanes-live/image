# airplanes.live feeder image

Notes specific to the airplanes.live fork of pi-gen. Upstream pi-gen docs live
in `README.md`.

## Flashing

If you use **Raspberry Pi Imager**, ensure version **2.0.9 or newer**. Earlier
versions have a known bug where the "Enable SSH" customization writes the SSH
public key but does not enable `ssh.service`, so SSH ends up refused on first
boot. The fix landed upstream in 2026-04-27 (commit `2c428de4`,
[raspberrypi/rpi-imager](https://github.com/raspberrypi/rpi-imager)).

For bare-flash users (`dd`, balenaEtcher, etc.) configure the feeder by editing
`/boot/firmware/airplanes-config.txt` on the FAT partition before first boot.
WiFi can be set there via `WIFI_SSID` / `WIFI_PASS` / `WIFI_COUNTRY`.

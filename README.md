# Tasmota for the eWeLink ZB-GW03: Zigbee + Matter

[Français](README.fr.md) · **English**

Tasmota firmware for the **eWeLink ZB-GW03** Zigbee gateway. A single build runs
**Zigbee** (coordinator, EZSP protocol) and **Matter**, so the gateway can be paired with
Google Home, Apple Home, Home Assistant or any other Matter controller.

No official Tasmota firmware has both: `tasmota32-zbbrdgpro` has Zigbee without Matter,
`tasmota32` has Matter without Zigbee.

## Contents

- [Hardware](#hardware)
- [Differences from the official build](#differences-from-the-official-build)
- [Download](#download)
- [First install over serial](#first-install-over-serial)
- [Update from an existing Tasmota](#update-from-an-existing-tasmota)
- [Configuration](#configuration)
- [OTA updates](#ota-updates)
- [Building](#building)
- [Troubleshooting](#troubleshooting)
- [Credits and license](#credits-and-license)

## Hardware

| Part | Component |
|---|---|
| Main MCU | ESP32-D0WD-V3, 4 MB flash, no PSRAM |
| Zigbee | EFR32MG21 module (Silicon Labs, EmberZNet firmware, EZSP protocol) |
| Ethernet | LAN8720 PHY (RMII) |
| Other | I2C EEPROM at 0x50, button, 2 LEDs |

Tested on a **ZB-GW03 v1.4** board (revision printed on the PCB), with EmberZNet
6.7.10.0 (EZSP v8) and Google Home as the Matter controller.

The ZB-GW03 is **not** a Sonoff ZBBridge Pro. The ZBBridge Pro has a CC2652P (Texas
Instruments, ZNP protocol); the ZB-GW03 has an EFR32MG21 (EZSP protocol), wired to other
pins. Tasmota compiles only one of the two protocols, so a ZBBridge Pro firmware cannot talk
to the ZB-GW03 Zigbee module.

## Differences from the official build

This build starts from the official `tasmota32-zbbrdgpro` environment and changes:

| Setting | Official `tasmota32-zbbrdgpro` | This repository |
|---|---|---|
| Zigbee protocol | ZNP (CC2652P) | EZSP (EFR32MG21) |
| Matter (`USE_MATTER_DEVICE`) | no | yes |
| `espressif/mdns` component | removed | kept (Matter advertises over mDNS) |
| `espressif/fb_gfx` component (camera) | kept | removed |
| Partitions | `app1856k_fs1344k` | `app2880k_fs320k` (safeboot) |
| `OTA_URL` | official firmware | latest release of this repository |
| CC2652P firmware and flasher in the file system | yes | no (useless on the EFR32) |
| Matter event timestamps (button presses) | seconds, 32 bits | milliseconds, 64 bits, as Matter requires (see [Zigbee button in Google Home](#zigbee-button-in-google-home)) |
| Berry `AES_CBC` and 128-bit `AES_GCM` with AAD | no | yes, for [local Tuya devices](docs/tuya-local.fr.md) |

With Matter, the image is about 2 MB (about 1990 KB). It does not fit in the 1856 KB slot of
the official layout, hence the **safeboot** layout: `safeboot` 832 KB, `app0` 2880 KB,
`spiffs` 320 KB. On a module already running Tasmota, check it in the Berry console:

```berry
import partition_core
for s: partition_core.Partition().slots print(s.label, s.sz / 1024) end
```

## Download

The [latest release](https://github.com/gnatali/tasmota32-zbgw03-matter/releases/latest)
provides:

| File | Use |
|---|---|
| `tasmota32-zbgw03-matter.factory.bin` | First install over serial, written at address `0x0` (bootloader, partition table, safeboot and firmware) |
| `tasmota32-zbgw03-matter.bin` | Update of a module already running Tasmota with the safeboot layout (file upload or OTA) |

Releases up to `v16.0.0.2-matter2` only contain the `.bin`. Each run of the **Build
firmware** workflow (**Actions** tab) provides both files in its `firmware` artifact (GitHub
login required, kept 90 days).

## First install over serial

Needed when the gateway still runs the eWeLink firmware, or when its flash layout is not
the safeboot layout above.

1. Open the case and connect a 3.3 V USB-serial adapter (CP2102, CH340...) to the ESP32
   serial pads: adapter TX → ESP32 RX, adapter RX → ESP32 TX, GND → GND. Power the board
   from its own USB supply if possible: the 3.3 V output of small adapters is often too weak
   for the ESP32 Wi-Fi (brownout resets).
2. Hold **IO0** to GND while powering on to enter download mode.
3. Install esptool (`pip install esptool`), then back up the whole flash (it contains the
   original firmware):

   ```bash
   esptool --port /dev/ttyUSB0 --baud 460800 read_flash 0 0x400000 zb-gw03-backup.bin
   ```

4. Erase, then write the factory image (enter download mode again before each command if
   needed):

   ```bash
   esptool --port /dev/ttyUSB0 erase_flash
   esptool --port /dev/ttyUSB0 --baud 460800 write_flash 0x0 tasmota32-zbgw03-matter.factory.bin
   ```

   On Windows the port is `COM3`, `COM5`...

5. Power cycle. Tasmota starts a Wi-Fi access point `tasmota-XXXXXX-XXXX`: connect to it,
   open `http://192.168.4.1` and enter your Wi-Fi settings.
6. Continue with [Configuration](#configuration).

## Update from an existing Tasmota

If the module already runs Tasmota with the safeboot layout:

1. Back up the configuration: **Configuration → Backup Configuration**.
2. **Firmware Upgrade → Upgrade by file upload** with `tasmota32-zbgw03-matter.bin`.
3. Continue with [Configuration](#configuration).

## Configuration

### GPIO template

The template declares the Zigbee module pins, Ethernet, LEDs, button and I2C. For the
**v1.4** board, the v1.2 template from [templates.blakadder.com](https://templates.blakadder.com/)
works unchanged (tested):

```
Backlog Template {"NAME":"ZB-GW03-V1.4","GPIO":[0,0,3552,0,3584,0,0,0,5793,5792,320,544,5536,0,5600,0,0,0,0,5568,0,0,0,0,0,0,0,0,608,640,32,0,0,0,0,0],"FLAG":0,"BASE":1}; Module 0
```

| GPIO | Function |
|---|---|
| 2 / 4 | Zigbee TX / RX |
| 13 / 12 | Zigbee Rst 1 (reset) / Rst 2 (EFR32 bootloader) |
| 14 / 15 | LED / link LED |
| 16 | Ethernet PHY power |
| 18 / 23 | Ethernet MDIO / MDC |
| 32 / 33 | I2C SCL / SDA (EEPROM at 0x50) |
| 34 | Button |

For another board revision, check the matching template. **Do not** apply the Sonoff
ZBBridge Pro template (`Sonoff_ZBPro.autoconf`): its pins do not match, and Zigbee no longer
starts.

### Zigbee

At boot, the console should show:

```
ZIG: Resetting EZSP device
RSL: RESULT = {"ZbState":{"Status":1,"Message":"EFR32 EZSP booted",...}}
RSL: RESULT = {"ZbState":{"Status":55,"Version":"6.7.10.0","Protocol":8,"Stack":2}}
RSL: RESULT = {"ZbState":{"Status":0,"Message":"Started"}}
ZIG: Zigbee started
```

`ZbInfo` lists the known devices. `ZbPermitJoin 1` opens pairing for 60 seconds; `ZbName`
renames a device. Tasmota only supports version 8 of the EZSP protocol.

### Ethernet

With the template above, `ETH: Ethernet using RMII` at boot is expected. `Ethernet 1` /
`Ethernet 0` turns the Ethernet port on or off (the module restarts).

Not yet tested on v1.4: if the link does not come up with a cable plugged in, a community
ESPHome configuration for v1.4 uses the clock output on GPIO17 and PHY address 1, that is
`Backlog EthType 0; EthAddress 1; EthClockMode 3`.

### Matter

1. Enable Matter: `SetOption151 1`, then `Restart 1`.
2. Pair from **Configuration → Matter** (QR code or manual pairing code) with your Matter
   controller.

Without PSRAM, Zigbee and Matter leave about 70 to 100 KB of free heap: watch `Heap` in
`Status 4`.

### Local Tuya devices

The Berry driver `berry/tuya_local.be` controls Tuya Wi-Fi devices (protocols 3.3, 3.4 and
3.5) and Tuya gateway sub-devices locally, without the cloud, and exposes them to Matter. It
is built into the firmware (solidified: its code stays in flash instead of being compiled into
RAM) and started from `autoexec.be`. The **Configuration → Tuya local** page discovers devices on
the network, imports their local keys (from tinytuya's `devices.json` or the Tuya cloud), creates
their Matter endpoints and edits the configuration; the same features are available as commands
(HTTP, MQTT). See [docs/tuya-local.fr.md](docs/tuya-local.fr.md) (user guide, French),
[docs/tuya-local-examples.en.md](docs/tuya-local-examples.en.md) (command, event, rule and script
examples) and [docs/tuya-local-dev.en.md](docs/tuya-local-dev.en.md) (technical documentation).

### Zigbee button in Google Home

Tasmota does not expose a Zigbee button to Matter, but it can create a **virtual Matter
button** that a rule triggers on each press. Tested with a Sonoff SNZB-01P and Google Home.

1. Press the button and watch the console: the `ZbReceived` line gives its short address
   (`0x922D` below) and the value of each press type. For the SNZB-01P: `Power` 2 for a
   single press, 1 for a double press, 0 for a long press.
2. **Configuration → Matter**: add a **v.Generic Switch/Button** device, named for example
   `Perron`.
3. Link the Zigbee button to the virtual button:

   ```
   Rule1 on ZbReceived#0x922D#Power=2 do MtrUpdate {"Name":"Perron","Presses":1} endon on ZbReceived#0x922D#Power=1 do MtrUpdate {"Name":"Perron","Presses":2} endon on ZbReceived#0x922D#Power=0 do MtrUpdate {"Name":"Perron","Presses":3} endon
   Rule1 1
   ```

   The virtual button only knows repeated presses (1 to 5): the long press arrives as a
   triple press.
4. `Restart 1`, so that the Matter controller subscribes to the new button.
5. In Google Home: **Automations → Add → Household**, starter **"Switch or button
   pressed"**, then the button and the press type.

Tasmota timestamps each Matter event in seconds, while Matter expects milliseconds: a press
seems to date from January 1970, and Google Home receives it without starting the
automation. This repository fixes it (`patches/matter-event-timestamp-ms.patch`), from
release `v16.0.0.2-matter4`. With `WebLog 3`, a press shows `MTR: +Add_Event` (button
events) then `MTR: <Sub_Data` (sent to the controller).

## OTA updates

GitHub always serves the latest release (not a draft, not a pre-release) at a fixed address,
which the module downloads over HTTPS, following the GitHub redirect:

```
https://github.com/gnatali/tasmota32-zbgw03-matter/releases/latest/download/tasmota32-zbgw03-matter.bin
```

This address is compiled into the firmware as `OTA_URL`, so that **Start upgrade** never
replaces this firmware with an official one without Matter. Once, in the console: `OtaUrl 1`
(restores the compiled `OTA_URL`). Then **Firmware Upgrade → Start upgrade**, or `Upgrade 1`
in the console, installs the latest release.

With the safeboot layout, `Upgrade 1` restarts the module into the `safeboot` partition, which
downloads the `.bin`, writes it to `app0` and restarts into the new firmware. Settings
(Wi-Fi, template, Zigbee, Matter) are kept.

A module still running a firmware named `zbbrdgpro-matter` (release `v16.0.0.2-matter1` and
earlier) asks for an old file name that newer releases no longer contain. Update it once by
**Upgrade by file upload**, or with
`OtaUrl https://github.com/gnatali/tasmota32-zbgw03-matter/releases/latest/download/tasmota32-zbgw03-matter.bin`
followed by `Upgrade 1`.

## Building

The firmware is built by GitHub Actions (`.github/workflows/build.yml`):

- **Actions → Build firmware → Run workflow** builds the firmware; the files are in the
  run's `firmware` artifact.
- Pushing a `v*` tag also publishes them as a **Release**:

  ```bash
  git tag v16.0.0.2-matter3
  git push --tags
  ```

The workflow builds a fixed Tasmota commit: branch `development`, commit
[`a281cec`](https://github.com/arendst/Tasmota/commit/a281cece518b0031e22f2317ca7dbc530c934da1)
(16.0.0.2, 4 November 2026). To follow a newer version, change `TASMOTA_REF` in the
workflow.

| File | Role |
|---|---|
| `platformio_override.ini` | `tasmota32-zbgw03-matter` environment: extends `tasmota32-zbbrdgpro`, adds Matter, sets partitions, `OTA_URL` and components |
| `user_config_override.h` | Replaces ZNP with EZSP (copied to `tasmota/` before the build) |
| `patches/*.patch` | Fixes applied to the Tasmota code before the build; the Matter Berry code is regenerated from its sources during the build |
| `.github/workflows/build.yml` | Clones Tasmota, copies both files, applies the fixes, builds, publishes |

To build locally, clone Tasmota at the same commit, copy `platformio_override.ini` to its
root and `user_config_override.h` to its `tasmota/` folder, apply the fixes
(`git -C tasmota apply ../patches/*.patch`), then run `pio run -e tasmota32-zbgw03-matter`.

When changing `TASMOTA_REF`, check that each fix still applies: otherwise the workflow
stops. A fix that became useless (fixed in Tasmota) can be deleted.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ZIG: rebooting ZNP device` then `timeout, goto label 99` | Firmware built for ZNP (ZBBridge Pro): install this firmware |
| `ZIG: Resetting EZSP device` then timeout | Wrong template: apply the ZB-GW03 template |
| `WIF: WifiManager active`, address `192.168.4.1` | Settings lost (for example after several quick power cycles): connect to the `tasmota-...` access point, then restore a backup with **Configuration → Restore Configuration** |
| No network, no LED | Read the serial log at 115200 baud on the ESP32 TX pad |
| HTTP commands (`/cm?cmnd=...`) refused | Send a `Referer` header while `SetOption128` is on |

## Credits and license

- [Tasmota](https://github.com/arendst/Tasmota) by Theo Arends and contributors, released
  under the GNU GPL v3.0: the firmware binaries of this repository are built from it, with
  the configuration files above.
- ZB-GW03 template: [templates.blakadder.com](https://templates.blakadder.com/).

This repository is released under the GNU GPL v3.0, like Tasmota: see [LICENSE](LICENSE).

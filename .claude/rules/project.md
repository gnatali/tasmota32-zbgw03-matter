---
paths:
  - "**"
---
# Project: context, hardware, repository layout

Custom Tasmota firmware for Guillaume's **eWeLink ZB-GW03** gateway: Zigbee (EFR32 in EZSP),
Ethernet and **Matter**, plus a Berry driver that controls **Tuya devices locally**. Language
rules: see `CLAUDE.md` § 2 (English for code, docs and commits; French translation of the user
documentation; conversations in French). The driver's web page follows the layout of Tasmota's
pages (see `berry-pitfalls.md`).

**Current work**: local Tuya devices, branch `tuya-local-crypto`, PR #7. The state, the
measurements made on the gateway and the next steps are in
[docs/tuya-local-tracking.en.md](../../docs/tuya-local-tracking.en.md): read it before resuming.

## Hardware (constraints that weigh on every choice)

- ESP32-D0WD, 4 MB flash, **no PSRAM**. Partitions: 2880 KB application, 320 KB file system
  (`esp32_partition_app2880k_fs320k.csv`). Current firmware: ~2050 KB with the solidified Tuya
  driver (web page, discovery, import), ~830 KB of flash left.
- **RAM is the critical resource**: ~67 KB free with Zigbee + Matter right after boot,
  ~71-74 KB after 30 s, **~48 KB** with the solidified Tuya driver and its 12 connected devices
  as well (the driver uses ~23 KB; ~40 KB when it was loaded from the file system, which left
  34 KB). Every new feature is measured with `Heap` in `Status 4` (in KB).

## Repository

| Path | Role |
|---|---|
| `platformio_override.ini` | `tasmota32-zbgw03-matter` environment, derived from `tasmota32-zbbrdgpro` + `USE_MATTER_DEVICE` + `USE_TUYA_LOCAL` (driver started at boot) and `custom_berry_solidify` (driver in flash) |
| `user_config_override.h` | build options (EZSP, `USE_BERRY_CRYPTO_AES_CBC`...) |
| `patches/*.patch` | patches applied to Tasmota by the workflow (`git apply`), in alphabetical order |
| `.github/workflows/build.yml` | build: clones Tasmota at commit `TASMOTA_REF`, driver tests, patches, `pio run` |
| `berry/tuya_local.be` | local Tuya driver (protocols 3.3/3.4/3.5, Tuya gateway, Matter bridge), solidified into the firmware (`custom_berry_solidify`) |
| `berry/tuya.example.json` | configuration example, **without keys** |
| `berry/test/` | driver test bench (see `tests-tuya.md`) |
| `docs/tuya-local.{en,fr}.md` | driver user guide |
| `docs/tuya-local-examples.{en,fr}.md` | examples of commands, events, rules, Berry scripts |
| `docs/tuya-local-dev.{en,fr}.md` | technical documentation (architecture, solidification, test bench, measurements) |
| `docs/tuya-local-tracking.{en,fr}.md` | Tuya work tracking |

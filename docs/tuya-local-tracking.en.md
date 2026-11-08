# Work tracking: local Tuya devices

*Version française : [tuya-local-tracking.fr.md](tuya-local-tracking.fr.md)*

Last update: **8 November 2026**. Branch `tuya-local-crypto`, PR #7 (not merged).

## Goal

Control from the ZB-GW03, **without the Tuya cloud and without flashing the devices**, the Tuya
Wi-Fi devices and the Zigbee sub-devices of the Tuya gateway, and expose them to **Matter**
(Google Home). It is the equivalent of LocalTuya for Home Assistant, but on the gateway.

## Status

| Step | Status |
|---|---|
| Berry crypto: `USE_BERRY_CRYPTO_AES_CBC` + `berry-aes-gcm-128-aad.patch` | ✅ built, in service on the gateway |
| `berry/tuya_local.be` driver: protocols 3.3 / 3.4 / 3.5, Tuya gateway (`cid`) | ✅ **tested on the real devices**: 5 Wi-Fi devices and 7 sub-devices connected, correct values |
| Test bench (22 scenarios) in the workflow | ✅ passes locally (source and solidified) |
| **Simplified configuration**: `/tuya` web page, UDP discovery, `devices.json` and cloud import, types deduced from the DPs, API (`TuyaConfig`, `TuyaAdd`, `TuyaDel`, `TuyaScan`, `TuyaImport`, `TuyaCloud`, `TuyaMatter`) | ✅ test bench; ✅ build (run 13, 2050 KB); ✅ discovery on the gateway (3 devices); ⏳ cloud import on the gateway (fix of run 16, not flashed yet) |
| **Driver solidification** (`custom_berry_solidify`, `berry-solidify-all-classes.patch`) | ✅ test bench: source **and** solidified driver; ✅ firmware build (2015 KB); ✅ on the gateway: **48 KB free with the 12 devices connected** (34 KB before), the driver uses ~23 KB instead of ~40 |
| User documentation `docs/tuya-local.{en,fr}.md` | ✅ |
| Start at boot without `autoexec.be` (enable checkbox, waits for Zigbee) | ✅ test bench; ⏳ gateway (run 19) |
| **Memory** with the 12 devices connected: 34 KB free with the driver loaded from the file system, **48 KB** with the solidified driver | ✅ ~14 KB of extra margin |
| Matter endpoints and tests in Google Home | ✅ 5 endpoints created (`Entrée-Porche`, `Ventilateur`, `Lumière ventilateur`, `Récepteur radio 1` and `4`), in Google Home after `Restart 1`; 61 KB free |
| Pergola 1 and 2 (RGB floodlights) | ⏳ not found by the scan: IP and version unknown, disabled in `tuya.json` |
| Migration of the Bureau and Salon Zigbee LED controllers to the ZB-GW03 | ⏳ decided, not done |

## History

1. **Research**: no LocalTuya equivalent exists for Tasmota. The protocol is described by
   TinyTuya (`PROTOCOL.md`). Tasmota's Berry had TCP, MD5 and HMAC-SHA256, but neither AES-ECB
   (`AES_CBC` exists, but must be enabled at build time) nor AES-128-GCM with AAD (`AES_GCM`
   only accepted 32-byte keys, without AAD).
2. **Scan** of the devices (`tinytuya scan`): two in 3.3, three in 3.5. There are also 9
   Zigbee devices on the Tuya gateway.
3. **Decision**: the Tuya gateway keeps its sub-devices, driven through it. Only the Zigbee
   lights (Bureau and Salon LED controllers) will be moved to the ZB-GW03.
4. **Crypto**: `AES_GCM` patch (16-byte keys, optional 4th AAD argument), checked against the
   `cryptography` library (40 cases), then the `AES_CBC` option.
5. **Driver and test bench**, then PR #7. The workflow (run by hand) passes: 12/12 tests,
   1992 KB firmware.
6. **On the gateway**: `load("tuya_local.be")` directly in `autoexec.be` crashed the ESP32 at
   boot. After 4 crashes, the boot-loop protection started without Berry (`Br` → `Unknown`,
   `/bc` not found, no Matter) and disabled the rules. Fix: load it 30 s after boot, if at
   least 60 KB are left. Everything has worked since.
7. **Solidification** (step 1 below): the driver is built into the firmware with
   `custom_berry_solidify = ../berry/tuya_local.be`. What had to change:
   - Tasmota's script (`pio-tools/solidify-from-url.py`) only registered the **first** class
     of a file in `be_modtab.c`: `berry-solidify-all-classes.patch`, for all the driver's
     classes;
   - a solidified class is read-only: the CRC table, computed on first call in a
     `static var`, is replaced by a constant 16-entry table (CRC by nibble, checked against
     `zlib.crc32` and the reference value `0xCBF43926`);
   - no more top-level code: imports inside the methods, instantiation in `autoexec.be`
     (`global.tuya_local = TuyaLocal()`), which still loads `tuya_local.be` if the firmware
     does not contain the driver;
   - the test bench solidifies the driver like the build (`berry_port`, `coc`) and replays the
     12 scenarios on the native classes. The generated C is ~206 KB of source.
   - **Build** (run 11, commit `df4ed7d`): 2,063,295-byte firmware (2015 KB, +22.3 KB), i.e.
     the growth of `.rodata` (676,464 → 699,280 bytes, +22.3 KB). Static RAM does not move
     (DRAM 65,948 → 65,980 bytes, +32). ~865 KB of flash left.

8. **Simplified configuration** (7 November), after a costed evaluation made beforehand
   (flash 25 to 35 KB, permanent RAM 1 to 2 KB, 22 to 28 KB peak for the cloud import):
   - **API**: `TuyaConfig` (without the keys), `TuyaAdd` (`***` key kept), `TuyaDel`,
     `TuyaStatus <device>`, `TuyaSend` by DP code; `/tuya.json.bak` backup;
   - **discovery** (`TuyaScan`, `TuyaScan` class created on demand): UDP announcements on 6666
     / 6667 / 7000 with the fixed key `md5("yGAdlopoPVldABfn")`, `REQ_DEVINFO` (0x25) request
     for 3.5 devices, like `tinytuya scan`;
   - **import** (`TuyaImport`) of tinytuya's `devices.json`, read in 512-byte chunks (objects
     over 8 KB skipped); Matter bindings deduced from the category and the DP codes;
     sub-devices attached to their gateway;
   - **cloud** (`TuyaCloud`, class created on demand): OpenAPI signature like tinytuya, one
     request per second, refused under 35 KB free (the HTTPS client reserves 16 KB);
   - **web page** `/tuya` (`TuyaWeb` class, static functions): list, JSON editing, discovery,
     imports, creation of the Matter endpoints then restart (`bridge_add_endpoint`, Matter's
     internal API, to be watched at every `TASMOTA_REF`).
   Test bench: 18 scenarios, 18/18 in source and solidified. Measured on the bench (64-bit,
   roughly to be halved for the ESP32): +0.7 to +1.3 KB at rest, +4.5 KB during a discovery
   finding 10 devices. Driver: ~1700 lines of code, 507 KB of solidified C.
   **Build** (run 13, commit `df91caf`): 2,099,167-byte firmware (2050 KB, **+34.2 KB**,
   within the 25 to 35 KB estimate), `.rodata` 735,056 bytes; static RAM +96 bytes (DRAM
   65,980 → 66,076). ~830 KB of flash left.

9. **Direct Zigbee → Tuya links** (7 November): `TuyaSend <device>,<dp>,toggle` inverts a
   boolean DP from the known state (scenario 19). Rule proposed for the SNZB-01P button
   `0x922D` (already linked to the virtual Matter button "Perron" by `Rule1`): `Rule2`, see
   `docs/tuya-local.en.md`. The discovery found the 3 devices on the gateway.
   Build: run 15 (commit `6b51e4a`), 19/19 in both modes, 2,099,471-byte firmware; to be
   flashed.

10. **Documentation** (7 November): `docs/tuya-local-dev.{en,fr}.md` (technical documentation:
    architecture, solidification, Matter, API, discovery, imports, web page, test bench,
    measurements) and `docs/tuya-local-examples.{en,fr}.md` (commands, responses, events,
    rules, Berry scripts), linked from the READMEs and the user guide, itself translated
    into English (`docs/tuya-local.en.md`).

11. **Cloud import: `{"Error":"cloud Tuya : reponse invalide"}`** (7 November, on the
    gateway): every OpenAPI response ends with `"t":<time in ms>` (13 digits), which exceeds
    Berry's 32-bit integers; `json.load` then returns `nil` for the whole document, from the
    token request on. The test bench did not see it (fake responses without `"t"`). Fix:
    `TuyaCloud.quote_big` quotes integers of more than 9 digits before `json.load`. Checked in
    the container with Guillaume's account: signature accepted, 33 real responses read (16
    devices, 16 keys, 150 DPs; the Tuya gateway answers `not support this device` to the
    specifications, which is normal). Scenario 17 extended (it fails without the fix). Build:
    run 16 (commit `1171ed1`), 19/19 in both modes, 2,099,967-byte firmware (+0.5 KB); to be
    flashed.

12. **Savable cloud credentials** (8 November): "save credentials" checkbox on the page,
    `"save":true|false` and `TuyaCloud` without argument for the command. Separate file,
    `/tuya_cloud.json`, so that `TuyaConfig`, the edit page and `tuya.json.bak` never expose
    them; secret never shown again; unchecked box = file emptied. Scenario 20 (20/20 in both
    modes). **No build**, at Guillaume's request: it will come with the next change.

13. **Web page in Tasmota's format, interface in English** (8 November): on a desktop screen,
    the page spread over the whole width (cloud form: list and fields side by side, long
    paragraphs), unlike Tasmota's pages (Matter). Now 340 px like Tasmota (320 px paragraphs,
    one field per block with its label, small table headers), checked by a screenshot with
    Tasmota's CSS. HTML pictograms for the actions (🔌 button, 📝 edit, 🔥 delete, 💾, ➕, 🔄,
    🔍, 📥, ☁️; states 🟢 🔴 ⚪ ⚠; discovery ✅/🆕). Page, responses, errors and log **in
    English**; endpoint names deduced on import unchanged (French). Tests and EN/FR docs
    adapted (20/20 in both modes). **No build**: to be run with the next change. The
    documentation's `autoexec.be` also logs in English (the one on the gateway still works
    as is).

14. **Language rule** (8 November): code comments, documentation, commit messages,
    `CLAUDE.md` and `.claude/rules/` are now **in English**; the user documentation is
    written in English (reference) and translated into French (`README.fr.md`,
    `docs/*.fr.md`). All the driver's comments, the test bench, the workflow, the build
    configuration and the patch headers were translated; this tracking file became
    `tuya-local-tracking.en.md` with its French translation. Renamed rule modules:
    `project.md`, `berry-pitfalls.md`. No functional change (20/20 in both modes); **no
    build**.

15. **Matter endpoint list with checkboxes** (8 November): on the gateway, the section listed
    the missing endpoints as plain text, and created all of them at once. It is now a table
    like the device list: one row per binding, ✅ and the endpoint number when it exists, a
    checkbox when it is missing (header checkbox for all); **➕ Create and restart** creates
    the ticked ones only (nothing ticked: refused). `TuyaMatter [name,name]` does the same by
    command. Scenario 18 extended (20/20 in both modes), page checked at 340 px. **No build**.
    **Checked**: Guillaume's screenshot listed as missing endpoints created earlier
    (`Entrée-Porche`, `Ventilateur`, `Récepteur radio 1` to `4`...): he had deleted them by hand
    in Configuration → Matter. The list was right: the driver reads Matter's configuration
    correctly on the gateway.

16. **No Matter: no `MtrUpdate`** (8 November): Matter detection is made at run time (the
    driver is the same in every firmware). Without the `matter_device` global (firmware built
    without Matter, or Matter disabled), `TuyaBinding.push()` now sends nothing and never makes
    a binding pending: before, every binding was refused ("Unknown" command) and resent every
    30 s for nothing. Scenario 21 (21/21 in both modes; it fails without the check). Build:
    run 18 (commit `7dc2e3a`), 2,105,743-byte firmware (2056 KB, +5.8 KB since run 16), static
    RAM unchanged (DRAM 66,076 bytes); it brings entries 12, 13, 15 and 16 to the gateway (run
    17, started by Guillaume on commit `36389bb`, had 12 and 13 but not 15). To be flashed.

17. **Start like Matter, without `autoexec.be`; greyed-out button while waiting** (8 November):
    `patches/tuya-local-autostart.patch` instantiates the driver in Tasmota's Berry init code,
    right after Matter. The instance is light; the driver only starts once enabled (**Tuya
    Local enable** checkbox on its page, or `TuyaEnable 0|1`, kept in `_persist.json`) and
    once Zigbee is started, the network is up, Matter is started (if enabled) and 45 KB are
    free. Meanwhile, the main page shows a greyed-out **⏳ Tuya Local** button and what it
    waits for, in the sensor area refreshed by the browser, like Zigbee's buttons; then an
    active **🔌 Tuya Local** button. An old `autoexec.be` creates an inert second instance and
    a warning. Also fixed: with Matter disabled, `matter_device` exists without configuration,
    so `push()` now also checks `plugins_config` (entry 16 only covered a firmware without
    Matter). Scenarios 0 and 1 (start), 12 and 21 adapted: 22/22 in both modes. Build: run 19
    (commit `e264ca8`), 2,112,271-byte firmware (2063 KB, +6.5 KB since run 18), static RAM
    unchanged (DRAM 66,076 bytes); to be flashed. On the gateway: **enable the driver once** after flashing (the setting starts unset), and remove
    the `tuya_start()` lines from `autoexec.be`.

18. **Driver stuck on "waiting for Matter"** (8 November, run 19 on the gateway): Matter was
    started (`MTR: Starting UDP server on port: 5540`) but the driver kept waiting. Cause:
    `matter_device.started` is declared by `Matter_zz_Device` but never set by Tasmota (it
    stays `nil`); the test bench's fake Matter set it to `true`, so the bench could not see
    it. Fix: Matter is considered started once its UDP server exists
    (`matter_device.udp_server`); the fake Matter now behaves like Tasmota (`started` left
    `nil`), and scenario 0 checks the wait for Matter (`MATTERUDP 0/1`). 22/22 in both modes.
    Build: run 20 (commit `9b579c3`), 2,112,271-byte firmware (same size as run 19); to be
    flashed.

19. **`USE_TUYA_LOCAL` build flag** (8 November): like `USE_MATTER_DEVICE` for Matter, the
    start of the driver in Berry's init code (`patches/tuya-local-autostart.patch`) is now
    under `#ifdef USE_TUYA_LOCAL`, and `platformio_override.ini` sets `-DUSE_TUYA_LOCAL`. The
    flag controls the start only: the classes come from `custom_berry_solidify` (without the
    flag, the driver is in flash but not started). Patch checked against `TASMOTA_REF`;
    driver unchanged (22/22). **No build yet.**

20. **Tasmota 16.0.0.3** (8 November): `TASMOTA_REF` moved from `a281cec` (16.0.0.2) to
    `43d9409` (head of `development`, 18 commits). Review of the changes:
    - **Matter event timestamps fixed upstream** (`4676a03`, new `tasmota.rtc_utc_ms()`): same
      encoding as our `matter-event-timestamp-ms.patch` (tag `0x2703`, uint64 ms), with true
      millisecond resolution. Our patch no longer applied: **removed**;
    - web server: the `Referer` check of privileged pages now requires `host/` or `ip/`
      (security fix): compatible with the Tuya Local forms (posted from the same gateway);
    - `subStr()` / `ArgV()` bounds, settings migration from versions below 9.1 removed,
      Matter attestation timestamp, sensors and displays: no effect on this firmware;
    - unchanged: Berry, BearSSL, `pio-tools` (solidification), Zigbee, `Matter_zz_Device`
      (`plugins_config`, `udp_server`, `bridge_add_endpoint`), the Berry init code.
    The three remaining patches apply; test bench 22/22 in both modes on the new Berry. Build:
    run 21.

## Measurements on the gateway

| Situation | `Heap` (`Status 4`) |
|---|---|
| After the firmware update, before the driver | 67 KB |
| 30 s after boot, just before loading the driver | 74 KB |
| Driver loaded, 12 devices connected, no Tuya Matter endpoint | **34 KB** |
| **Solidified driver** (2015 KB firmware, 6 November): just before starting the driver | 71 KB |
| **Solidified driver**: driver started, 3 devices connected | 61 KB |
| **Solidified driver**: driver started, **12 devices connected** (Matter endpoint `Entrée-Porche` created) | **48 KB** |
| Reduced scope (3 devices), `Entrée-Porche` endpoint only, 7 November | 62 KB |
| + `Ventilateur` (v.Fan), after `Restart 1` | 58 KB |
| + `Lumière ventilateur` (v.Light 0 OnOff), after `Restart 1` | 61 KB |
| + `Récepteur radio 1` and `Récepteur radio 4` (v.Relay), after `Restart 1`: **5 endpoints** | **61 KB** |
| Run 13 firmware (web page, discovery, import), driver started, no discovery | **55 KB** |
| … right after a discovery | 53 KB |
| … after a discovery then `Br tasmota.gc()` | 55 KB |
| Run 13, just before the driver starts (`autoexec.be`) | 73 KB |
| … driver started, 3 devices connected, readings at 5, 10 and 12 min (`STATE`, `Status 4`) | 56, 62, 60 KB |

With the 12 devices connected, the driver used about **40 KB** when loaded from the file
system (74 − 34: code compiled into RAM, device state, buffers), and about **23 KB** solidified
(71 − 48: state and buffers only). Solidification thus removed **~17 KB** of code from RAM;
**48 KB are free instead of 34** (+14 KB, the starting heap being 3 KB lower: 71 versus
74 KB). The state alone costs ~23 KB for 12 devices, i.e. ~2 KB per device on average: it
grows with the number of connected devices and of received DPs (clamp: 22 DPs, gateway: 7
sub-devices). With 3 devices, 10 KB (71 → 61). The 48 KB include the `Entrée-Porche` Matter
endpoint. There was no measurement after `Br tasmota.gc()`.

**Run 13 firmware**: the discovery costs ~2 KB while it runs, all given back after
`Br tasmota.gc()` (no leak). At rest, the heap **varies from 56 to 62 KB** from one reading
to the next; with 73 KB just before the driver, it uses **11 to 17 KB** (10 KB with run 12,
single measurement). The extra cost is therefore within the measurement noise, consistent with
the test bench (+0.7 KB on 64 bits). Berry's heap is 51 KB (`STATE`).

**Cost of the Matter endpoints**: from 62 KB (1 endpoint) to 61 KB (5 endpoints), i.e.
**~1 KB for 4 endpoints**, within the measurement noise (the intermediate 58 KB is part of
it: the heap varies by a few KB from one reading to the next). The ~60 KB margin is therefore
comfortable.

**Breakdown on the test bench** (solidified driver, 64-bit interpreter: on the ESP32, Berry
objects are about half the size): driver without devices ~3.7 KB; first device ~8 KB
(including the test `crypto` module); each extra node ~2.6 KB (`dps` state, configuration
kept as a map, `rx`/`tx` buffers, connection objects). Stable over 3 min of operation: no
leak.

**Rewrite the driver in C?** Studied on 6 November, set aside for now. The gain would be
limited to the devices' Berry state (around 1 KB per device on the ESP32, to be confirmed):
TCP connections cost as much in C, and the Matter endpoints (Berry) do not change. Costs: a
large Tasmota patch to maintain at every `TASMOTA_REF`, the test bench to rewrite, and an
error in C crashes the ESP32 (boot loop, Matter disabled). First: reduce the Berry state
(step 3) and measure the cost of the Matter endpoints.

## Inventory (no keys or ids: see `tuya.json` on the gateway)

**Chosen scope (7 November)**: only the Ventilateur, the Récepteur radio and Entrée-Porche
are active in `tuya.json`, plus Pergola 1 and 2 disabled (`"enabled": false`, unknown IP,
version 3.3 assumed). The clamp meter and the Tuya gateway (with its sub-devices) are **not**
in `tuya.json`: out of scope. That is **7 Matter endpoints** (9 with the Pergolas), instead
of 16. With 3 devices connected, the driver uses ~10 KB (71 → 61 KB).

**Wi-Fi devices**

| Device | Protocol | Role in `tuya.json` |
|---|---|---|
| Ventilateur (fan) | 3.5 | `fan` (DP 60/62, speeds 1-6) + `light0` (DP 20) |
| Récepteur radio (4-channel 433 MHz receiver) | 3.5 | 4 × `relay` (DP 1 to 4) |
| Entrée-Porche (LSC CCT bulb) | 3.3 | `light2` (DP 20/21/22/23) |
| A:Eau B:Chfg C:Cuisine (3-circuit clamp meter) | 3.5 | out of scope (not in `tuya.json`) |
| Gateway (Tuya Zigbee gateway) | 3.3 | out of scope (not in `tuya.json`), with its sub-devices |
| Pergola 1, Pergola 2 (LSC RGB floodlights) | ? | `light3` (DP 20/21/22/24), `"enabled": false` |

**Zigbee sub-devices of the Tuya gateway** (out of scope): luminaires terrasse, Prise Lisseur
and Relais zigbee Cuisine (`relay_power`, DP 1/18/19/20); Interrupteur Terrasse and Chauffage
(`relay`); Temperature SdB (`temp` DP 1 and `humidity` DP 2, divider 10); Capteur de
température et d'humidité (`temp` DP 103 and `humidity` DP 101, divider 100).

**To be moved to the ZB-GW03**: Bureau and Salon LED controllers (E2-ZR), which will become
`z_light2` or `z_light1` Matter endpoints.

## Next steps (by priority)

1. ~~**Solidify the driver**~~: done and measured, 48 KB free with the 12 devices instead of
   34 (see the measurements). The driver now starts by itself (entry 17) with at least 45 KB
   free (71 KB before the driver starts, ~23 KB used afterwards).
2. **Matter**: create the endpoints one by one, with **exactly** the `ep` name (accents
   included), and test both directions with Google Home, reading `Heap` after each:
   - ✅ `Entrée-Porche`: v.Light 2 CT;
   - ✅ `Ventilateur`: v.Fan; ✅ `Lumière ventilateur`: v.Light 0 OnOff;
   - ✅ `Récepteur radio 1` and `Récepteur radio 4`: v.Relay. Channels 2 and 3 have no
     endpoint: remove them from `tuya.json` if they are not used (otherwise the driver tries
     to update them every 30 s, to no effect).
   **`Restart 1` is mandatory** after creating them: without it, Google Home shows the new
   devices offline. Both directions remain to be tested (Google Home → device, and device →
   Google Home: button, Smart Life, remote) for each endpoint.
3. **Reduce the driver's RAM** if the Matter endpoints do not leave enough margin (unlikely
   with 3 devices, ~10 KB):
   - only keep in `dps` the DPs used by a binding or a sensor (the clamp sends 22, the plugs
     11);
   - limit `publish_result` (one MQTT message per change, the clamp sends many).
4. **Validate the simplified configuration** on the gateway (after flashing): Configuration →
   Tuya Local page, discovery (the 3 devices must show up), `Heap` during and after, import
   of `devices.json` (then the cloud import, which exercises HTTPS to Tuya: to be tested with
   at least 35 KB free, with the run 16 fix or later), creation of the Matter endpoints from
   the page, saved cloud credentials, page layout on a desktop screen.
5. **Pergola 1 and 2**: switch them on, run the discovery of the Tuya Local page (or
   `tinytuya scan`), fill in `ip` and `version`, then remove `"enabled": false`.
6. **Move Bureau and Salon** to the ZB-GW03 (procedure in `docs/tuya-local.en.md`).
7. **Merge PR #7** once Matter is validated, then create a `v*` tag to publish the release.

## To check on the gateway

- **`MtrUpdate` answers `Done`** for an endpoint that publishes no state (`v_fan`): the driver
  took it for a refusal (`TUY: endpoint Matter 'Ventilateur' : Done (nouvel essai toutes les
  30 s)`, log of the time, now in English) and resent the fan's state every 30 s. Fixed
  (`Matter_zz_Device.MtrUpdate` answers: the state, or `Done`, otherwise an error message),
  scenario 1 extended. Build: run 14 (commit `b8b2789`), 18/18 in both modes, 2,099,215-byte
  firmware; to be flashed.
- **Berry stack trace** seen 14 s after the driver started (`stack traceback: <native>: in
  native function`, `BRY: stack[2] = type='function' ()`), without the error line preceding
  it: unknown origin (driver, Matter or other). To be captured in full if it comes back.
- The gateway is connected over **Wi-Fi** (192.168.100.13), on the same network as the
  devices: the discovery uses it (Wi-Fi address if Ethernet has none).

- **First Matter endpoint (`Entrée-Porche`, v.Light 2 CT)**: once created, it stayed "not
  connected" in Google Home until an `MtrUpdate {"Name":"Entrée-Porche","Power":1}` made by
  hand; since then everything works, including after `Restart 1`. First hypothesis: the
  driver only sends state **changes** to Matter. If it received the bulb's state before the
  endpoint was created, its `MtrUpdate` failed (`Invalid Device`) and was never resent: the
  endpoint kept its default values. Fix considered: resend a binding's full state while its
  `MtrUpdate` fails (every 30 s), so that an endpoint created on the fly gets its state
  without a restart. **Done**: `TuyaBinding.push()` makes the binding pending on the first
  refusal (reported once), `TuyaLocal.sync_pending()` resends it the full state every 30 s,
  and any device update resends it too. Scenario 13 of the test bench (it fails on the old
  driver). Build: run 12, 2,064,191-byte firmware (+0.9 KB). **Flashed on 7 November**: the
  first flash failed (gateway left in safeboot), the second one worked.
  **Hypothesis disproved on 7 November**: with this firmware, the following endpoints show up
  in Google Home but stay **offline until Tasmota's `Restart 1`**, although the driver does
  send them their state. The real cause is on the Matter side: Google Home only subscribes to
  new endpoints when it reconnects. For `Entrée-Porche`, it was therefore probably a restart,
  not the manual `MtrUpdate`, that unblocked everything. Conclusion: **`Restart 1` after
  creating the endpoints, always** (once for several). The state resend stays in place: no
  visible effect, but it prevents an endpoint from keeping default values if Matter creates
  it after the driver.

- `Rule1`: the boot-loop protection disabled the rules. Check that `Rule1 1` was done again
  (Zigbee button "Perron" in Google Home).
- **Flash left in safeboot** (7 November, run 12): flashing again from the safeboot page was
  enough, with the unzipped `.bin` of the artifact. Tasmota only switches to safeboot by
  itself after 10 consecutive restarts within the first 10 seconds: the driver, started at
  30 s, cannot be the cause.
- The exact cause of the crash was not captured (`Status 12` not collected). The delayed
  start is enough, but if a crash comes back, `Status 12` is the first thing to ask for.

## Files outside the repository

| File | Where | Content |
|---|---|---|
| `devices.json`, `snapshot.json` | Guillaume's PC (output of `tinytuya wizard` / `scan`) | local keys, ids, IPs, versions |
| `/tuya.json` | gateway file system | real configuration, **with the keys** |
| `/tuya_cloud.json` | gateway file system | Tuya cloud credentials, if saved from the page |
| `/autoexec.be` | gateway file system | user rules only: the driver no longer needs it (entry 17); remove the old `tuya_start()` lines |
| `/_persist.json` | gateway file system | `tuya_local`: driver enabled (checkbox / `TuyaEnable`) |

To resume development, ask Guillaume for the files the task needs. Never commit them.

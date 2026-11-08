# Local Tuya driver: technical documentation

*Version française : [tuya-local-dev.fr.md](tuya-local-dev.fr.md)*

This document describes what was developed on 6 and 7 November 2026 on the
`tuya-local-crypto` branch (PR #7): solidification of the driver into the firmware,
synchronisation with Matter, configuration from the gateway (API, discovery, key import, web
page), direct links with Zigbee, and the test bench that covers all of it. The user guide is
[tuya-local.en.md](tuya-local.en.md); command and event examples are in
[tuya-local-examples.en.md](tuya-local-examples.en.md).

The driver's web page, responses and console messages are in English, like Tasmota, and so are
the code comments. This English documentation is the reference; it is translated into French
([tuya-local-dev.fr.md](tuya-local-dev.fr.md)).

## Contents

1. [Architecture](#1-architecture)
2. [Solidification into the firmware](#2-solidification-into-the-firmware)
3. [Synchronisation with Matter](#3-synchronisation-with-matter)
4. [Configuration file and API](#4-configuration-file-and-api)
5. [Network discovery](#5-network-discovery)
6. [Importing tinytuya's devices.json](#6-importing-tinytuyas-devicesjson)
7. [Importing from the Tuya cloud](#7-importing-from-the-tuya-cloud)
8. [Web page](#8-web-page)
9. [TuyaSend toggle and Zigbee links](#9-tuyasend-toggle-and-zigbee-links)
10. [Test bench](#10-test-bench)
11. [Measurements](#11-measurements)
12. [Limitations and open points](#12-limitations-and-open-points)
13. [Files](#13-files)

## 1. Architecture

The driver is a single file, `berry/tuya_local.be`, with nine classes. Each one is solidified
into the firmware (one `#@ solidify:<Class>,weak` directive per class).

| Class | Role | RAM footprint |
|---|---|---|
| `TuyaCodec` | protocol primitives: CRC-32, HMAC, AES-ECB, 6699 frames, UDP announcements | static functions, no instance |
| `TuyaBinding` | link between Tuya DPs and a virtual Matter endpoint (conversions both ways, `MtrUpdate`) | one per `matter` entry |
| `TuyaNode` | logical device (Wi-Fi device or gateway sub-device): last `dps` state, bindings, readings, `codes` table | one per device or sub-device |
| `TuyaDevice` | TCP connection and protocol 3.3 / 3.4 / 3.5 (inherits `TuyaNode`) | one per Wi-Fi device |
| `TuyaScan` | discovery of devices on the local network | **created on demand**, released at the end |
| `TuyaImport` | turns tinytuya or cloud devices into `tuya.json` entries, deduces bindings | static functions |
| `TuyaCloud` | signed requests to Tuya's OpenAPI | **created on demand**, released at the end |
| `TuyaWeb` | Configuration → Tuya Local page | static functions |
| `TuyaLocal` | the Tasmota driver: configuration, loop, commands, events | one instance, created by `autoexec.be` |

`TuyaLocal.every_50ms()` runs the connections, the current discovery, the current cloud import
(one request per second) and the resend to Matter (every 30 s).

## 2. Solidification into the firmware

**Why**: loaded from the file system, the driver compiled its code into RAM, about 17 KB of the
40 KB it used with 12 devices. Solidified, that code lives in flash.

**How**:

- `platformio_override.ini`: `custom_berry_solidify = ../berry/tuya_local.be` (path relative
  to the Tasmota repository, cloned into `tasmota/` by the workflow).
- Tasmota's script `pio-tools/solidify-from-url.py` only registered the first class of a file in
  `be_modtab.c`. The patch `patches/berry-solidify-all-classes.patch` registers every class that
  has a `#@ solidify:` directive: without it, classes that call each other by their global
  name (`TuyaDevice`, `TuyaCodec`...) could not be found.
- `weak` option: strings stay out of the global table; Tasmota's `coc` generator scans
  `berry_custom/src/solidify` and creates their definitions.

**Constraints**, checked by the test bench:

- **no top-level code** outside classes: solidification runs the file without `tasmota`. The
  driver is instantiated by `autoexec.be` (`global.tuya_local = TuyaLocal()`), which still loads
  `tuya_local.be` if the firmware does not include the driver;
- **imports inside methods** (`import string`, `json`, `crypto`, `webserver`...): a top-level
  import does not exist in the firmware;
- **read-only classes**: a `static var` cannot be written
  (`attribute_error ... cannot assign to static attribute`). The CRC table, formerly computed on
  first use, became a constant 16-entry table (nibble CRC, checked against `zlib.crc32` and the
  reference value `0xCBF43926`);
- a `tuya_local.be` loaded with `load()` overrides the solidified driver (its classes become
  globals that hide the native classes), so a new version can be tried without reflashing.

## 3. Synchronisation with Matter

- `TuyaBinding.push(changed)` converts the changed DPs into attributes and sends
  `MtrUpdate {"Name":"<ep>",...}`.
- `MtrUpdate` answers (source: `Matter_zz_Device.be`): the endpoint state
  (`{"MtrUpdate":{...}}`), or `Done` for an endpoint that publishes no state (`v_fan`), otherwise
  an error message (`Invalid Device`, `Invalid attribute '...'`...). The first two are successes.
- On the first refusal, the binding becomes **pending** and the refusal is logged once.
  `TuyaLocal.sync_pending()` resends it the **full state** every 30 s (`SYNC_RETRY`), and so does
  any new value from the device. As soon as the endpoint accepts:
  `TUY: Matter endpoint '<ep>' available, state sent`.
- In Google Home, a new endpoint stays **offline until Tasmota's `Restart 1`** (the controller
  only subscribes to new endpoints when it reconnects), whatever state the driver sends.

## 4. Configuration file and API

- `read_conf()`: a missing or empty `/tuya.json` gives an empty configuration; an invalid file
  raises an error and is **never overwritten**.
- `write_conf()`: copies the previous version to `/tuya.json.bak`, writes indented JSON, then
  the configuration is reloaded (`load_config()`).
- `save_device(d, ref)`: adds or replaces a device, designated by `ref` (id or name, case
  insensitive) or by its `id`. A missing, empty or `***` key keeps the stored key. A name or id
  already used by another device is refused.
- `load_config()` skips devices with `"enabled": false` and those without `ip`, `key` or `id`.

Commands (all available from the console, HTTP `/cm?cmnd=` and MQTT `cmnd/<topic>/`):

| Command | Function | Response |
|---|---|---|
| `TuyaStatus [device]` | connection state and last values | `{"TuyaStatus":{...}}` |
| `TuyaSend <device>,<dp or code>,<value or toggle>` | send a value | `Done` or an error message |
| `TuyaReload` | reload `tuya.json` | `Done` |
| `TuyaConfig [device]` | configuration, keys replaced by `***` | `{"TuyaConfig":{...}}` |
| `TuyaAdd <json>` | add or replace a device | `{"TuyaAdd":"<name>"}` |
| `TuyaDel <device>` | delete | `{"TuyaDel":"<name>"}` |
| `TuyaScan [s]` | discovery (20 s, 60 at most) | immediate, then a `TuyaScan` event |
| `TuyaImport [file] [all\|id,...]` | import `devices.json` | `{"TuyaImport":{"Added":[...],"Updated":[...],"Skipped":[...]}}` |
| `TuyaCloud [json]` | import from the cloud | immediate, then a `TuyaCloud` event |
| `TuyaMatter` | create the missing Matter endpoints | `{"TuyaMatter":{"Added":[...],"Restart":"..."}}` |

The new commands go through `run_cmd()`: an expected error (`tuya_error`) becomes
`{"<command>":{"Error":"<message>"}}`; an unexpected one is also logged. Background operations
(discovery, cloud) publish their result through `report()`: log, `RESULT` (MQTT and rules) and a
message on the web page.

## 5. Network discovery

Ported from `tinytuya scan` (`scanner.py`, `udp_helper.py` in TinyTuya 1.20):

- listens on UDP ports **6666** (3.1, plain), **6667** (3.3, AES-ECB) and **7000** (3.5, 6699
  frame with AES-GCM); fixed key `md5("yGAdlopoPVldABfn")` (`TuyaCodec.UDP_KEY`);
- 55AA frame: 16-byte header, 4-byte return code, data, CRC and suffix; data is plain if it
  starts with `{`, encrypted otherwise. 6699 frame: 18-byte header (bytes 4 to 17 as
  authenticated data), 12-byte IV, data, 16-byte tag; the return code is removed if it precedes
  `{`; trailing NUL bytes are removed (`TuyaCodec.decode_udp`);
- 3.5 devices only announce themselves on request: every 6 s, a 6699 `REQ_DEVINFO` frame
  (command `0x25`) containing `{"from":"app","ip":"<gateway address>"}` (Ethernet, otherwise
  Wi-Fi) is broadcast to `255.255.255.255:7000`. Our own request, received on port 7000, is
  ignored (`from` field);
- result per id (`gwId`): `id`, `ip`, `version`, `product_key`. It is published at the end of
  the discovery and kept (`scan_result`) for the page and the imports.

Memory guard: at least 15 KB free to start a discovery.

## 6. Importing tinytuya's devices.json

- **Chunked reading** (`TuyaImport.each_object`): the file is read in 512-byte blocks, the
  objects of the array are found by a small state machine (brace depth, strings, escapes) and
  parsed one at a time. An object over 8 KB is skipped (log `JSON object
  too big`). The file size is therefore not limited by RAM.
- **Selection**: by default, the devices found by the last discovery or already configured, and
  the sub-devices whose gateway is; `all`: all of them; `id,id`: those ones.
- **Created entry** (`TuyaImport.entry`): `name`, `id`, `key` (or `local_key`), `ip` and
  `version` from the file, otherwise from the discovery, `matter` bindings, `sensors` readings,
  `codes` table. No key: skipped. No known IP: `"enabled": false`. Sub-device (`"sub":true`):
  `cid` = `node_id`, attached to its gateway (`parent` or `gateway_id`).
- **Merge** (`TuyaImport.merge`): an already configured device (same `id`) **keeps its
  bindings**; only its key, IP and version are updated, and only if the import knows them (fix:
  the version of a known device is no longer replaced by 3.3).
- **Binding deduction** (`TuyaImport.auto`), from the Tuya category and the DP codes:

| Case | DP codes | Binding |
|---|---|---|
| fan (`fs`, `fsd`, `fskg`, or a speed code) | `switch` / `fan_switch` + integer `fan_speed` / `fan_speed_percent` | `fan` (speed range from the mapping); enum speed: `relay` |
| … with a light | `light` / `switch_led` | `light0` "Lumière <name>" |
| light | `switch_led` + `bright_value(_v2)` + `colour_data_v2` / `temp_value_v2` | `light3` / `light2` / `light1` / `light0` (brightness range from the mapping, `work_mode`) |
| plug with metering | a single `switch` + `cur_power` (+ `cur_voltage`, `cur_current`) | `relay_power`, divisors 10^scale (and mA → A) |
| switches | `switch`, `switch_1` … `switch_8` | one `relay` per channel ("<name> 1", "<name> 2"...) |
| sensor | `va_temperature` / `temp_current`, `va_humidity` / `humidity_value` | `temp`, `humidity` (divisor 10^scale) |
| energy meter (`zndb`, `dlq`) | integer DPs with a unit | `sensors` |

Endpoint names are truncated to 32 bytes without splitting a UTF-8 character.

## 7. Importing from the Tuya cloud

Ported from `tinytuya.Cloud` (`Cloud.py`):

- hosts per region: `eu` openapi.tuyaeu.com, `we` openapi-weaz.tuyaeu.com, `us`
  openapi.tuyaus.com, `ue` openapi-ueaz.tuyaus.com, `cn` openapi.tuyacn.com, `in`
  openapi.tuyain.com, `sg` openapi-sg.iotbing.com;
- requests: `GET /v1.0/token?grant_type=1` (token), then for each device
  `GET /v1.0/devices/<id>` (name, `local_key`, category) and
  `GET /v1.1/devices/<id>/specifications` (`status` and `functions` → DP mapping);
- signature: `HMAC-SHA256(secret, client_id + [access_token] + t + "GET\n" + sha256("") +
  "\n\n" + path)` in upper-case hex, `t` in milliseconds (NTP time required); headers
  `client_id`, `sign`, `t`, `sign_method`, `mode`, and `access_token`, or `secret` for the token
  request (as tinytuya does). The test bench compares the signature with `tinytuya.Cloud`'s;
- **one request per second** (each request blocks during the TLS handshake); **35 KB free**
  required before each request (Tasmota's HTTPS client reserves a 16 KB buffer,
  `HttpClientLight`);
- devices: those given in `"devices"`, otherwise those of the last discovery. Sub-devices are
  not handled;
- credentials: saved only on request (page checkbox, `"save":true`) in `/tuya_cloud.json`
  (`TuyaLocal.CLOUD_CONF`), apart from `tuya.json` so that `TuyaConfig`, the edit page and
  `tuya.json.bak` never expose them; `TuyaLocal.cloud_start` fills an empty Access ID or Access
  Secret with the saved ones; `"save":false` (box unchecked) empties the file. The page shows the
  region and the Access ID again, never the secret.

## 8. Web page

- Registration: `web_add_config_button()` (**🔌 Tuya Local** button on the Configuration page) and
  `web_add_handler()` (`GET` and `POST /tuya` routes). Since the driver starts after the web
  server, Tasmota does not call its `web_add_handler()`: the driver calls it itself, only if
  `webserver.state() > 0` (`webserver.on()` crashes the ESP32 if the server is not running).
- `TuyaWeb.page()`: message of the last action, *Tuya devices*, *Matter endpoints*, *Network
  discovery* and *Import local keys* sections; `?edit=<ref>`: JSON editing (key replaced by
  `***`).
- Layout of Tasmota's pages (like Matter's): Tasmota's container is an `inline-block` at least
  340 px wide that grows to its widest content, so text goes in `<p style='width:320px;'>`
  (`TuyaWeb.p`), each form field in its own `<p><b>Label</b><br><input></p>` block (side by side,
  a select and two inputs widened the page to 600 px), table headers in `font-size:smaller`
  (`TuyaWeb.th`). Actions use HTML pictograms, as Tasmota does (📝 edit, 🔥 delete, as in the file
  manager): device states in `TuyaWeb.STATES` (🟢 🔴 ⚪ ⚠), ✅/🆕 in the discovery.
- Language: the page, responses, errors and logs are in English (like Tasmota); the names of
  the Matter endpoints deduced on import stay in French (`Lumière <name>`, `<name> humidité`),
  as they are what Google Home shows.
- `TuyaWeb.post()`: `save`, `del`, `reload`, `scan`, `import`, `cloud`, `matter` actions, then a
  redirect to `/tuya` (or `/?rst=` to restart after creating endpoints).
- Matter endpoints: `matter_names()` reads `matter_device.plugins_config` (lower-case name →
  endpoint number); `matter_status()` gives each binding (one per endpoint name) with its
  endpoint number or `nil`, which the page lists; `matter_missing()` keeps the `nil` ones. The
  page names the missing ones' checkboxes `m0`, `m1`... (value: endpoint name), and the post
  passes the ticked names to `matter_create(only)` (`nil`: all of them, as `TuyaMatter`
  without argument), which calls
  `matter_device.bridge_add_endpoint(<v_... type>, {"name": <ep>})` (Matter's internal API, the
  one its own configuration page uses).

## 9. TuyaSend toggle and Zigbee links

`TuyaSend <device>,<dp>,toggle` inverts a boolean DP from the last received state
(`node.dps`); it is refused if that state is unknown or not a boolean. A Tasmota rule can thus
link a Zigbee button to a Tuya device without Berry or the cloud (see the examples). A Tuya
device's state message (`{"Tuya":{"Name":...,"Dps":{...}}}`, published by
`tasmota.publish_result`) also triggers rules, which allows the opposite direction.

## 10. Test bench

`berry/test/run_tests.sh <Tasmota repository>` builds **two interpreters** from Tasmota's Berry
and BearSSL:

1. **source driver**: the harness compiles `tuya_local.be` in strict mode, like `load()`;
2. **solidified driver**: `tuya_local.be` is solidified as in the build (Python port
   `berry_port`, `solidify_all_python.be`), the string table is generated by `coc`, and the
   native classes are linked into the interpreter (`be_modtab.c` recompiled with a `modules.h`
   that declares them), read-only as in flash.

The same scenarios run on both. Mocks (`harness.be`, `webserver.be`, `crypto.be`): `tasmota`
(time, rules, commands, free memory, addresses), `tcpclientasync`, `udp`, `webclient` (responses
prepared per path), `webserver`, `matter_device`. The fake devices (`fake_tuya.py`) and the UDP
announcements (`udp_broadcast()`, checked with `decrypt_udp()`) are built with TinyTuya.

| No. | Scenario |
|---|---|
| 1 | connection, key negotiation, initial state (6 devices, 3.3 / 3.4 / 3.5, gateway); `Done` answer accepted |
| 2 to 5 | Matter → 3.5 fan, 3.3 CCT bulb, 3.4 RGB floodlight, Zigbee gateway |
| 6 | `SENSOR` readings and main page |
| 7 | `TuyaSend`, `TuyaStatus` |
| 8 to 11 | heartbeat and reconnection, silent device, corrupted frame, fragmented or grouped frames |
| 12, 13 | missing Matter endpoint, then created later (full state resent) |
| 14 | API: `TuyaConfig` without keys, `TuyaAdd` (key kept), `TuyaSend` by code, `TuyaDel`, `.bak` |
| 15 | discovery: 3.1 / 3.3 / 3.5 announcements, 3.5 request, ignored packets, memory guard |
| 16 | `devices.json` import: selection, deduced types, sub-device, object too big, `all` |
| 17 | cloud import: signature identical to TinyTuya's, key and DPs, cloud error, memory guard |
| 18 | web page: list, editing (masked key then kept), deletion, Matter endpoint list (✅ and number, checkboxes), creation of a selection only, none ticked refused, `TuyaMatter <names>`, discovery |
| 19 | `TuyaSend ... toggle` |
| 20 | saved cloud credentials: page checkbox, secret never shown, `TuyaCloud` without argument, erasing |

The workflow runs the bench before compiling; it creates `/tuya.json`, `/tuya.json.bak`,
`/devices.json` and `/tuya_cloud.json`, which the test writes.

## 11. Measurements

**Firmware** (GitHub Actions builds):

| Run | Content | Size | Delta |
|---|---|---|---|
| 10 | driver loaded from the file system | 2,040,447 bytes | |
| 11 | solidified driver | 2,063,295 bytes | +22.3 KB |
| 12 | resend to Matter | 2,064,191 bytes | +0.9 KB |
| 13 | API, discovery, imports, web page | 2,099,167 bytes | +34.2 KB |
| 14 | `Done` answer | 2,099,215 bytes | |
| 15 | `toggle` | 2,099,471 bytes | |

Static RAM (DRAM): 65,948 bytes before, 66,076 after (+128 bytes overall).

**Free memory on the gateway** (`Heap` in `Status 4`):

| Situation | Heap |
|---|---|
| driver loaded from the file system, 12 devices | 34 KB |
| solidified driver, 12 devices | 48 KB |
| solidified driver, 3 devices, 5 Matter endpoints | 61 KB |
| run 13, just before the driver starts | 73 KB |
| run 13, driver started, 3 devices (successive readings) | 56 to 62 KB |
| during a discovery / after `Br tasmota.gc()` | −2 KB / back to normal |

Virtual Matter endpoints cost less than 1 KB for four. On the test bench (64-bit), the
simplified configuration adds 0.7 to 1.3 KB at rest.

## 12. Limitations and open points

- **HTTPS to the Tuya cloud**: signature identical to TinyTuya's and checked against the real
  cloud (token, details, specifications); real responses are read by `json.load` thanks to
  `TuyaCloud.quote_big` (the `"t"` timestamp in ms is too large for Berry's 32-bit integers).
  Still to be validated on the gateway (TLS, at least 35 KB free).
- `bridge_add_endpoint()` is an internal Matter API: to be checked whenever `TASMOTA_REF`
  changes.
- The `TuyaCloud` command is logged by the web console, secret included: prefer the web page,
  or `TuyaCloud` without an argument with saved credentials.
- Not handled on import: `temp_value` (old 0 to 255 format), enum fan speed, `colour_data` (old
  format); sub-devices through the cloud.
- Discovery does not cross a router (UDP broadcast).
- A Berry stack trace without an error message was seen 14 s after the driver started
  (unknown origin).

## 13. Files

| File | Content |
|---|---|
| `berry/tuya_local.be` | the driver (9 classes) |
| `patches/berry-solidify-all-classes.patch` | registration of all solidified classes |
| `platformio_override.ini` | `custom_berry_solidify` |
| `berry/test/run_tests.sh` | builds the two interpreters, solidification, scenarios |
| `berry/test/harness.be`, `webserver.be`, `crypto.be` | Tasmota mocks |
| `berry/test/fake_tuya.py`, `test_tuya_local.py` | fake devices, UDP announcements, 20 scenarios |
| `.github/workflows/build.yml` | files written by the tests |
| `docs/tuya-local.en.md` / `.fr.md` | user guide |
| `docs/tuya-local-examples.fr.md` / `.en.md` | command and event examples |
| `docs/tuya-local-tracking.{en,fr}.md` | project tracking, measurements |

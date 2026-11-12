# Local Tuya devices (a LocalTuya equivalent)

*Version française : [tuya-local.fr.md](tuya-local.fr.md)*

The Berry driver `berry/tuya_local.be` controls Tuya devices **without flashing them and
without the cloud**, directly over the local network, and exposes them to **Matter** (Google
Home, Apple Home...) through the gateway.

Command, event, rule and script examples:
[tuya-local-examples.en.md](tuya-local-examples.en.md); internals:
[tuya-local-dev.en.md](tuya-local-dev.en.md).

- Tuya local protocols **3.3, 3.4 and 3.5** (TCP 6668, encrypted with the local key).
- **Zigbee sub-devices of a Tuya gateway** (plugs, switches, sensors that stay paired with the
  Tuya gateway).
- Matter bridge: each function of a Tuya device becomes a **virtual Matter endpoint**. A
  Google Home command goes to the Tuya device, and a change made on the device (button, Smart
  Life app, remote control) shows up in Google Home.
- Readings (clamp meter...) in Tasmota's `SENSOR` telemetry and on the main page.

It requires a firmware from this repository, which includes the `berry-aes-gcm-128-aad.patch`
patch and the `USE_BERRY_CRYPTO_AES_CBC` option (the official Tasmota firmware cannot encrypt
the 3.5 protocol).

The driver's web page, command responses, error messages and console messages are in English,
like the rest of Tasmota.

## Contents

- [Preparing the devices](#preparing-the-devices)
- [Installing the driver](#installing-the-driver)
- [Web page: adding and managing devices](#web-page-adding-and-managing-devices)
- [Creating the Matter endpoints](#creating-the-matter-endpoints)
- [Configuration file](#configuration-file)
- [Commands](#commands)
- [Direct links with a Zigbee button](#direct-links-with-a-zigbee-button)
- [Moving Zigbee devices to the ZB-GW03](#moving-zigbee-devices-to-the-zb-gw03)
- [Limitations](#limitations)
- [Tests](#tests)

## Preparing the devices

Devices can now be discovered and imported **from the gateway** (see
[Web page](#web-page-adding-and-managing-devices)): only the local key needs the Tuya cloud,
once. With TinyTuya on a PC, the procedure is still possible:

1. **Local keys**: on a PC, `py -m pip install tinytuya` then `py -m tinytuya wizard` (Tuya IoT
   developer account linked to the Smart Life app). The resulting `devices.json` file contains,
   for each device, its `id`, its local key `key` and, for Zigbee sub-devices, their `node_id`
   (the driver's `cid`).
2. **Addresses and versions**: `py -m tinytuya scan` writes `snapshot.json` with the IP address
   (`ip`) and the protocol version (`ver`) of each Wi-Fi device that answers.
3. **Fixed addresses**: reserve the IP address of each Wi-Fi device in the DHCP server (the
   router), otherwise the driver loses the device when its address changes.

The local key changes each time a device is paired again in Smart Life: run the `wizard`
again and update `tuya.json`.

## Installing the driver

1. Update the gateway with a firmware from this repository. The driver is **built in**
   (solidified): its code lives in flash instead of being compiled into RAM when loaded. There
   is no `tuya_local.be` file to upload any more (deleting an old copy is safe: it is only
   loaded if the firmware does not include the driver).
2. **Tools → Manage File system**: upload `tuya.json` (or create the devices later from the
   page: discovery and import).
3. **Enable the driver**, like Matter: **Configuration → 🔌 Tuya Local**, tick **Tuya Local
   enable**, **💾 Save** (or the `TuyaEnable 1` command). The setting is kept across restarts
   (`_persist.json`). **No `autoexec.be` is needed**: the firmware instantiates the driver at
   boot, like Matter's `matter_device`, and the driver itself waits for the right moment. This
   is enabled at build time by the `USE_TUYA_LOCAL` flag (like `USE_MATTER_DEVICE` for Matter),
   set in this repository's `platformio_override.ini`.
4. At each boot, the driver only connects to the devices once **Zigbee is started** (or absent),
   the **network** is up, **Matter** is started (if enabled) and at least **45 KB** of memory
   are free. Meanwhile, the main page shows a greyed-out **⏳ Tuya Local** button with what it
   waits for (like Zigbee's buttons during its initialisation); then the button becomes
   **🔌 Tuya Local** and opens the page. The console shows:

   ```
   TUY: waiting for Zigbee
   TUY: starting, free memory 72 KB
   TUY: 5 device(s), 16 Matter endpoint(s)
   TUY: Ventilateur (192.168.1.18) connected, protocol 3.5
   ...
   ```

5. `TuyaStatus` lists each device with `"Connected":true` and its values. Check the free memory
   (`Heap` in `Status 4`) once all devices are connected: the ZB-GW03 has no PSRAM.

**Coming from an `autoexec.be` that started the driver** (`tuya_start()`, `global.tuya_local =
TuyaLocal()`, `load("tuya_local.be")`): delete those lines, then enable the driver as above.
If they stay, they create a second instance that does nothing but log
`TUY: driver already started by the firmware: remove the tuya_local lines from autoexec.be`,
and `tuya_local` in the Berry console then points to that idle instance. The driver must not
be started directly in `autoexec.be` anyway: on the ZB-GW03 (no PSRAM), loading it while Zigbee
and Matter were starting crashed the ESP32; after four quick crashes, Tasmota's boot-loop
protection starts **without Berry** (hence without Matter) and **disables all rules**.

To stop the driver: untick the box (or `TuyaEnable 0`): connections are closed at once.

## Web page: adding and managing devices

**Configuration → 🔌 Tuya Local** (`/tuya`), or the **🔌 Tuya Local** button of the main page
once the driver runs. The page follows the layout of Tasmota's own pages (340 px wide), with
pictograms for the actions.

- **Tuya Local**: **Tuya Local enable** checkbox and the driver's state (🟢 running, ⏳ what it
  waits for, ⚪ disabled). While the driver is not running, the devices show ⏸ and the Matter
  section is empty.

- **Tuya devices**: name, IP, version and state of each `tuya.json` entry (🟢 connected,
  🔴 disconnected, ⚪ disabled, ⚠ incomplete). **📝** opens the entry as JSON (same format as the
  file): the key is replaced by `***`, and a key left as `***` is kept when saving (**💾 Save**;
  **⏸️ Disable** sets the device aside without deleting it, **▶️ Enable** turns it back on;
  **🔥 Delete** removes the device). **➕ Add device** offers a template. Each save keeps the
  previous version in `/tuya.json.bak`, then reloads the configuration. **🔄 Reload tuya.json**
  reads the file again.
- **Network discovery → 🔍 Discover devices (20 s)**: listens to the Wi-Fi devices'
  announcements on the local network (UDP ports 6666, 6667, 7000) and asks 3.5 devices to
  announce themselves, like `tinytuya scan`. Gives the IP and version of each one (✅ already
  configured, 🆕 new), sorted by IP. A device does not announce its name, so each row shows what
  is known from elsewhere, in this order: the name in `tuya.json` (type deduced from its Matter
  binding), the name and category of `/devices.json` (if the file is on the gateway; the keys are
  not kept), then, with **🏷️ Identify (cloud)**, the name, category and product name given by the
  Tuya cloud (no key fetched, `tuya.json` untouched). Otherwise the row says *unknown* with the
  product key and the end of the id (the full id is in the tooltip). The gateway and the devices
  must be on the **same local network** (announcements do not cross a router).

  **Tick** the devices (nothing is ticked at first; the header checkbox ticks them all), then
  **📥 Import selection (devices.json)** or **☁️ Import selection (cloud)**: only the ticked
  devices are imported. The cloud buttons use the **saved** credentials (see below).
  **🏷️ Identify (cloud)** looks up the ticked devices, or the unknown ones if none is ticked.
- **Import local keys**, two options:
  - **📥 Import file**: `tinytuya wizard`'s `devices.json`, uploaded through **Tools → Manage
    File system**. It is read in chunks: its size is not limited by memory. The devices found by
    the discovery or already configured are imported (or all of them, **all** checkbox), with
    their Zigbee sub-devices;
  - **☁️ Import from cloud**: the Tuya cloud directly, for the devices found by the discovery.
    Choose the **Region** and enter the **Access ID** and **Access Secret** of the Tuya IoT
    project (the same developer account as for `tinytuya wizard`). With the **save credentials**
    checkbox, they are kept in `/tuya_cloud.json` (never in `tuya.json`): the page then fills in
    the region and the Access ID, and an Access Secret left empty uses the saved one; the secret
    is never shown again. Unchecking the box erases the file (the current import still uses the
    credentials once). The time must be set (NTP) and **35 KB of free memory** is required
    (Tasmota's HTTPS client reserves 16 of them); the import makes one request per second, and
    the result is shown on the page.

  The import completes `tuya.json`: a new device gets its key, its IP and version (from the
  discovery), its **Matter bindings deduced from its DPs** (light, fan, plug with or without
  metering, multi-gang switches, temperature and humidity sensor, energy meter) and the `codes`
  table of its DPs. An already configured device keeps its bindings: only its key, IP and
  version are updated. A device without a known IP is added with `"enabled": false`.
- **Matter endpoints**: one row per binding, like the device list, with a checkbox (the header
  checkbox ticks them all): endpoint name, Matter type and its state: ✅ and its number when the
  endpoint exists (same name, case-insensitive), ⚠ when it is missing, ⏸️ when the binding is
  disabled. On the ticked rows: **➕ Create and restart** creates the missing endpoints (types
  in the table below), then restarts Tasmota, which Google Home needs; **⏸️ Disable** disables
  the bindings without deleting them (no more updates to Matter, no more "Invalid Device
  (retry every 30 s)" for an endpoint you do not want); **▶️ Enable** turns them back on.

## Creating the Matter endpoints

The **Tuya Local** page creates them in one click (see above). By hand:

In **Configuration → Matter**, add one endpoint per `matter` entry of `tuya.json`, of the type
below and with **exactly** the name given in `ep` (32 bytes at most; an accented letter counts
for 2). Then **`Restart 1`, required**: Google Home shows the new device straight away, but
**offline** until Tasmota restarts (the controller only subscribes to new endpoints when it
reconnects). Simplest: create all the endpoints, then a single `Restart 1`.

On the driver side, an endpoint that does not exist yet is reported once, and the driver resends
it the device state every 30 s until it accepts it. Without Matter (firmware built without it, or
Matter disabled), the driver sends nothing to Matter: the devices are still controlled by
command, rule and web page, and the page shows "Matter is not enabled".

| `type` in `tuya.json` | Matter endpoint to create | Exchanged attributes |
|---|---|---|
| `relay` | v.Relay | on/off |
| `relay_power` | v.Relay+Power | on/off, power, voltage, current |
| `light0` | v.Light 0 OnOff | on/off |
| `light1` | v.Light 1 Dimmer | on/off, brightness |
| `light2` | v.Light 2 CT | on/off, brightness, colour temperature |
| `light3` | v.Light 3 RGB | on/off, brightness, hue, saturation |
| `fan` | v.Fan | speed (0 = off) |
| `temp` | v.Temperature | temperature |
| `humidity` | v.Humidity | humidity |

If a name matches no endpoint, the console says so once:
`TUY: Matter endpoint 'xxx': Invalid Device (retry every 30 s)`. As soon as the endpoint
exists: `TUY: Matter endpoint 'xxx' available, state sent`.

## Configuration file

`tuya.json` (complete example without keys: [`berry/tuya.example.json`](../berry/tuya.example.json)):

```json
{"devices": [
  {"name": "Ventilateur", "id": "bf64xxxx...", "key": "local key", "ip": "192.168.1.18", "version": "3.5",
   "matter": [
     {"ep": "Ventilateur", "type": "fan", "dp": 60, "dp_speed": 62, "speed_max": 6},
     {"ep": "Lumière ventilateur", "type": "light0", "dp": 20}]},
  {"name": "Gateway", "id": "bf22xxxx...", "key": "local key", "ip": "192.168.1.180", "version": "3.3",
   "children": [
     {"name": "Prise Lisseur", "id": "bfc4xxxx...", "cid": "a4c138xxxxxxxxxx",
      "matter": [{"ep": "Prise Lisseur", "type": "relay_power", "dp": 1,
                  "dp_power": 19, "div_power": 10, "dp_voltage": 20, "div_voltage": 10,
                  "dp_current": 18, "div_current": 1000}]}]},
  {"name": "Pince", "id": "bf90xxxx...", "key": "local key", "ip": "192.168.1.80", "version": "3.5",
   "sensors": {"Total puissance": [133, 1, "W"], "Total energie": [131, 100, "kWh"]}}
]}
```

**Device** (TCP connection): `name`, `id`, `key`, `ip`, `version` (`"3.3"`, `"3.4"` or
`"3.5"`), and `"enabled": false` to set it aside. A Tuya gateway declares its sub-devices in
`children` (`name`, `id`, `cid` = `node_id` from `devices.json`). `"enabled": false` also
works on a sub-device and on a `matter` entry: it is kept in the file but ignored (page,
`TuyaActive`). To save RAM, the driver only
keeps the values of the DPs it uses (those of the `matter` bindings and `sensors`, plus every
boolean DP for `toggle`); `"keep": [63, 64]` keeps others, `"keep": "all"` keeps them all. The
other DPs are still published in the `Tuya` event (rules can use them), but `TuyaStatus` does
not show them. The `codes` table (import) is not kept in RAM either: `TuyaSend` by code reads it
from `tuya.json` when used.

**`matter` entry**: `ep` (endpoint name), `type`, and the DP numbers (defaults are those of
common Tuya bulbs and fans):

| Key | Role | Default |
|---|---|---|
| `dp` | on/off (or sensor value) | 1; 20 for lights; 60 for `fan` |
| `dp_mode` | mode (`white` / `colour`) | 21 |
| `dp_bri`, `bri_min`, `bri_max` | brightness and its range | 22, 10, 1000 |
| `dp_ct`, `ct_min`, `ct_max` | colour temperature (0 = warm, 1000 = cold) and its range in mireds | 23, 153, 500 |
| `dp_colour` | colour in `colour_data_v2` format (`hhhhssssvvvv`) | 24 |
| `dp_speed`, `speed_min`, `speed_max` | fan speed | 62, 1, 6 |
| `div` | sensor divisor (`temp`, `humidity`) | 10 |
| `dp_power` / `dp_voltage` / `dp_current` and `div_...` | `relay_power` readings | none |

The meaning of each device's DPs is in the `mapping` of `devices.json` (`code`, `scale`: a
`scale` of 1 gives a divisor of 10, a `scale` of 3 a divisor of 1000).

**`sensors`**: `"label": [dp, divisor, "unit"]`. The values appear in the `SENSOR` telemetry
(`{"Tuya":{"Pince":{"Total puissance":592,...}}}`) and on the main page.

## Commands

| Command | Effect |
|---|---|
| `TuyaStatus [device]` | Connection state and last values of each device (or of one): the DPs kept (used ones, booleans, `keep`) |
| `TuyaSend <device>,<dp>,<value>` | Sends a value, for example `TuyaSend Ventilateur,60,true` or `TuyaSend Ventilateur,62,3`. The DP can also be a code (`TuyaSend Lampe,switch_led,true`) if the device has a `codes` table (import). `toggle` inverts a boolean DP: `TuyaSend Entrée-Porche,20,toggle` |
| `TuyaActive <name>[,<name>...],<0\|1>` | Disables (`0`) or enables (`1`) without deleting them devices, gateway sub-devices (name or id) or, if no device has that name, Matter bindings (endpoint name): `TuyaActive Récepteur radio 3,Récepteur radio 4,0` → `{"TuyaActive":{"Disabled":["Récepteur radio 3","Récepteur radio 4"]}}` |
| `TuyaEnable [0\|1]` | Enables or disables the driver (kept across restarts), like the page's checkbox; without argument, gives the state: `{"TuyaEnable":{"Enabled":true,"State":"running"}}` (`State`: `running`, `disabled`, `waiting for Zigbee`...) |
| `TuyaReload` | Reloads `tuya.json` and reconnects the devices (driver running only) |
| `TuyaConfig [device]` | Configuration (`tuya.json`) **without the keys**, or that of one device |
| `TuyaAdd <json>` | Adds or replaces a device (same format as a `devices` entry); `"key":"***"` or no key: key kept |
| `TuyaDel <device>` | Deletes a device |
| `TuyaScan [seconds]` | Network discovery (20 s by default, 60 at most); result published at the end: `{"TuyaScan":{"Devices":[...]}}` |
| `TuyaImport [file] [all\|id,id]` | Imports tinytuya's `devices.json` (`/devices.json` by default) |
| `TuyaCloud [json]` | Import from the cloud: `{"region":"eu","id":"<Access ID>","secret":"<Access Secret>"}` (and `"devices":[...]` to choose the ids, `"names":true` to only identify them (name and type, no key, `tuya.json` untouched), `"save":true` to save the credentials, `"save":false` to erase them); without an argument, the saved credentials; result published at the end. **The web console logs the command, secret included**: prefer the web page, or `TuyaCloud` without an argument once the credentials are saved |
| `TuyaMatter [name,name]` | Creates the missing Matter endpoints, all of them or only those named (case-insensitive), then `Restart 1` |

These commands make up the **remote control API**: over HTTP
(`http://<gateway>/cm?cmnd=TuyaSend%20Ventilateur,60,true`, with `&user=admin&password=...` if a
web password is set) or MQTT (`cmnd/<topic>/TuyaSend`). Responses are JSON
(`{"TuyaAdd":"Lampe"}`, or `{"TuyaAdd":{"Error":"..."}}`).

Each state change is published on `stat/<topic>/RESULT`:
`{"Tuya":{"Name":"Ventilateur","Dps":{"62":3}}}`. Rules can use it.

## Direct links with a Zigbee button

A Tasmota rule links a ZB-GW03 Zigbee device to a Tuya device, **locally**: without Google
Home, the cloud or the internet. Example with the Sonoff SNZB-01P button `0x922D` (`Power` 2:
single press, 1: double press, 0: long press):

```
Rule2 on ZbReceived#0x922D#Power=2 do TuyaSend Entrée-Porche,20,toggle endon on ZbReceived#0x922D#Power=1 do TuyaSend Ventilateur,20,toggle endon on ZbReceived#0x922D#Power=0 do TuyaSend Récepteur radio,1,toggle endon
Rule2 1
```

- Single press: Entrée-Porche light; double press: fan light; long press: radio receiver
  channel 1. The name is the device's name in `tuya.json` (not the Matter endpoint's), the
  number is the DP's.
- `toggle` starts from the state known to the driver: the device must be connected and must
  have sent that state already (`TuyaStatus <device>`).
- One button can drive several rules: `Rule1` (virtual Matter button "Perron" for Google Home)
  and `Rule2` both fire. Do not also create, in Google Home, an automation acting on the same
  light: the two actions would cancel each other.
- Two-position switch: `TuyaSend <device>,<dp>,true` and `false` instead of `toggle`.

In the other direction, each state change of a Tuya device triggers rules
(`{"Tuya":{"Name":...,"Dps":{...}}}`); to filter on the device name, a Berry rule
(`tasmota.add_rule("Tuya", ...)` in `autoexec.be`) is safer than a Tasmota rule.

## Moving Zigbee devices to the ZB-GW03

For a Zigbee device of the Tuya gateway that you would rather control directly from the
ZB-GW03 (the Bureau and Salon LED controllers, for example):

1. In Smart Life, remove the device ("Remove and wipe data").
2. In the ZB-GW03 console: `ZbPermitJoin 1`.
3. Put the device back into pairing mode (for an LED controller, usually several quick power
   cycles: see its manual). `ZbInfo` lists it once paired.
4. `ZbName 0x1234,Bureau` to give it a name.
5. **Configuration → Matter**: add a **Zig Light 2 CT** endpoint (`z_light2`, tunable white),
   or **Zig Light 1 Dimmer** (`z_light1`, dimmer only), with the Zigbee name as argument. Then
   `Restart 1`.

It no longer appears in Smart Life; remove it from `tuya.json` if it was there.

## Limitations

- **Memory**: the page and the driver read `tuya.json` entry by entry, but changing the
  configuration (save, delete, imports, `TuyaConfig`) loads the whole file: these actions need
  **30 KB free** and are refused below (`not enough free memory: ...`) rather than risk a crash.
  `tuya.json` is written entry by entry and restored from `tuya.json.bak` if the write fails, so
  it is never left empty; `tuya.json.bak` is not replaced when `tuya.json` is empty.
- **Import**: an entry of `devices.json` over **8 KB** (large icon or mapping) is skipped and
  reported (`N object(s) too big`): import those devices from the cloud. In a cloud import, a
  device whose specifications the cloud refuses (`not support this device`, typically the Tuya
  Zigbee gateway) is still added, without bindings: complete its `matter` section by hand. The
  cloud import waits (up to 5 s) when memory is momentarily short instead of stopping.
- **One local connection per device**: do not use LocalTuya, tuya-local or TinyTuya on the same
  devices at the same time. The Smart Life app keeps working (through the cloud).
- Colours: only the `colour_data_v2` format (12 hex characters) is supported.
- Import: a `temp_value` colour temperature (old 0 to 255 format) is not used (the light becomes
  a dimmer), nor is an enum fan speed (the fan becomes a plain on/off). The cloud import does not
  handle Zigbee sub-devices (they do not announce themselves on the network): use tinytuya's
  `devices.json`.
- Commands go through when the device is connected; otherwise they are ignored (log:
  `not connected, command ignored`), and the driver reconnects by itself (5 s, then up to 60 s
  between attempts).
- A device silent for more than 35 seconds is disconnected, then reconnected.

## Tests

`berry/test/run_tests.sh <Tasmota repository>` compiles Tasmota's Berry interpreter with
Tasmota's BearSSL encryption, and runs 28 scenarios against fake Tuya devices built on
[TinyTuya](https://github.com/jasonacox/tinytuya) (3.3, 3.4, 3.5, Zigbee gateway): key
negotiation, Matter commands, state feedback, readings, disconnection and reconnection,
corrupted or fragmented frames, Matter endpoint created later, API, discovery (announcements in
TinyTuya's format), `devices.json` import, cloud import (signature compared with TinyTuya's),
web page, `toggle`. The **Build firmware** workflow runs them before each compilation, on the
source driver then on the solidified driver.

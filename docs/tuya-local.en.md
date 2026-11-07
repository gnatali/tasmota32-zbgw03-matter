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

The driver's console messages, error messages and web page are in French; their meaning is
given in this guide.

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
2. **Tools → Manage File system**: upload `tuya.json`.
3. Create (or complete) `autoexec.be` to start the driver **30 seconds after boot**, and only
   if enough memory is left:

   ```berry
   def tuya_start()
     import global
     var free = tasmota.memory()['heap_free']
     if free < 60
       tasmota.log(f"TUY: driver non demarre, memoire libre insuffisante ({free} Ko)", 2)
       return
     end
     tasmota.log(f"TUY: demarrage du driver, memoire libre {free} Ko", 2)
     # firmware without the built-in driver: load the tuya_local.be file
     if !global.contains("TuyaLocal")  load("tuya_local.be")  end
     global.tuya_local = TuyaLocal()
   end
   tasmota.set_timer(30000, tuya_start)
   ```

   The driver is a class: `TuyaLocal()` starts it, and `global.tuya_local` keeps it reachable
   from the Berry console (`tuya_local.devices`...). An old `autoexec.be` that only does
   `load("tuya_local.be")` no longer starts the driver.

   **Do not** start the driver as soon as `autoexec.be` runs: on the ZB-GW03 (no PSRAM), doing
   it while Zigbee and Matter are starting crashed the ESP32. After four quick crashes,
   Tasmota's boot-loop protection starts **without Berry** (hence without Matter: `Br` answers
   `Unknown`) and **disables all rules** (re-enable them afterwards with `Rule1 1`...). If in
   trouble, `SetOption153 1` prevents `autoexec.be` from running at the next boot.

4. `Restart 1`. After 30 seconds, the console shows (driver started with the free memory,
   number of devices and Matter endpoints, then each connection):

   ```
   TUY: demarrage du driver, memoire libre 74 Ko
   TUY: 5 appareil(s), 16 endpoint(s) Matter
   TUY: Ventilateur (192.168.1.18) connecte, protocole 3.5
   ...
   ```

5. `TuyaStatus` lists each device with `"Connected":true` and its values. Check the free memory
   (`Heap` in `Status 4`) once all devices are connected: the ZB-GW03 has no PSRAM.

## Web page: adding and managing devices

**Configuration → Tuya local** (`/tuya`):

- **Devices** (*Appareils*): name, IP, version and state (connected, disconnected, disabled) of
  each `tuya.json` entry. **Edit** (*Modifier*) opens the entry as JSON (same format as the
  file): the key is replaced by `***`, and a key left as `***` is kept when saving. **Add a
  device** (*Ajouter un appareil*) offers a template. Each save keeps the previous version in
  `/tuya.json.bak`, then reloads the configuration.
- **Discover devices (20 s)** (*Rechercher les appareils*): listens to the Wi-Fi devices'
  announcements on the local network (UDP ports 6666, 6667, 7000) and asks 3.5 devices to
  announce themselves, like `tinytuya scan`. Gives the id, IP and version of each one. The
  gateway and the devices must be on the **same local network** (announcements do not cross a
  router).
- **Import the local keys** (*Importer les clés locales*), two options:
  - `tinytuya wizard`'s `devices.json`, uploaded through **Tools → Manage File system**. It is
    read in chunks: its size is not limited by memory. The devices found by the discovery or
    already configured are imported (or all of them, *tous* checkbox), with their Zigbee
    sub-devices;
  - **the Tuya cloud directly**, for the devices found by the discovery: choose the region and
    enter the **Access ID** and **Access Secret** of the Tuya IoT project (the same developer
    account as for `tinytuya wizard`). They are not stored. The time must be set (NTP) and
    **35 KB of free memory** is required (Tasmota's HTTPS client reserves 16 of them); the
    import makes one request per second, and the result is shown on the page.

  The import completes `tuya.json`: a new device gets its key, its IP and version (from the
  discovery), its **Matter bindings deduced from its DPs** (light, fan, plug with or without
  metering, multi-gang switches, temperature and humidity sensor, energy meter) and the `codes`
  table of its DPs. An already configured device keeps its bindings: only its key, IP and
  version are updated. A device without a known IP is added with `"enabled": false`.
- **Matter endpoints**: lists the bindings that have no Matter endpoint with the same name.
  **Create the endpoints and restart** (*Créer les endpoints et redémarrer*) creates them
  (types in the table below) then restarts Tasmota, which Google Home needs.

## Creating the Matter endpoints

The **Tuya local** page creates them in one click (see above). By hand:

In **Configuration → Matter**, add one endpoint per `matter` entry of `tuya.json`, of the type
below and with **exactly** the name given in `ep` (32 bytes at most; an accented letter counts
for 2). Then **`Restart 1`, required**: Google Home shows the new device straight away, but
**offline** until Tasmota restarts (the controller only subscribes to new endpoints when it
reconnects). Simplest: create all the endpoints, then a single `Restart 1`.

On the driver side, an endpoint that does not exist yet is reported once, and the driver resends
it the device state every 30 s until it accepts it.

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
`TUY: endpoint Matter 'xxx' : Invalid Device (nouvel essai toutes les 30 s)` (retried every
30 s). As soon as the endpoint exists: `TUY: endpoint Matter 'xxx' disponible, etat envoye`
(available, state sent).

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
`children` (`name`, `id`, `cid` = `node_id` from `devices.json`).

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
| `TuyaStatus [device]` | Connection state and last values of each device (or of one) |
| `TuyaSend <device>,<dp>,<value>` | Sends a value, for example `TuyaSend Ventilateur,60,true` or `TuyaSend Ventilateur,62,3`. The DP can also be a code (`TuyaSend Lampe,switch_led,true`) if the device has a `codes` table (import). `toggle` inverts a boolean DP: `TuyaSend Entrée-Porche,20,toggle` |
| `TuyaReload` | Reloads `tuya.json` and reconnects the devices |
| `TuyaConfig [device]` | Configuration (`tuya.json`) **without the keys**, or that of one device |
| `TuyaAdd <json>` | Adds or replaces a device (same format as a `devices` entry); `"key":"***"` or no key: key kept |
| `TuyaDel <device>` | Deletes a device |
| `TuyaScan [seconds]` | Network discovery (20 s by default, 60 at most); result published at the end: `{"TuyaScan":{"Devices":[...]}}` |
| `TuyaImport [file] [all\|id,id]` | Imports tinytuya's `devices.json` (`/devices.json` by default) |
| `TuyaCloud <json>` | Import from the cloud: `{"region":"eu","id":"<Access ID>","secret":"<Access Secret>"}` (and `"devices":[...]` to choose the ids); result published at the end. **The web console logs the command, secret included**: prefer the web page |
| `TuyaMatter` | Creates the missing Matter endpoints (then `Restart 1`) |

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

- **One local connection per device**: do not use LocalTuya, tuya-local or TinyTuya on the same
  devices at the same time. The Smart Life app keeps working (through the cloud).
- Colours: only the `colour_data_v2` format (12 hex characters) is supported.
- Import: a `temp_value` colour temperature (old 0 to 255 format) is not used (the light becomes
  a dimmer), nor is an enum fan speed (the fan becomes a plain on/off). The cloud import does not
  handle Zigbee sub-devices (they do not announce themselves on the network): use tinytuya's
  `devices.json`.
- Commands go through when the device is connected; otherwise they are ignored (log:
  `non connecte, commande ignoree`), and the driver reconnects by itself (5 s, then up to 60 s
  between attempts).
- A device silent for more than 35 seconds is disconnected, then reconnected.

## Tests

`berry/test/run_tests.sh <Tasmota repository>` compiles Tasmota's Berry interpreter with
Tasmota's BearSSL encryption, and runs 19 scenarios against fake Tuya devices built on
[TinyTuya](https://github.com/jasonacox/tinytuya) (3.3, 3.4, 3.5, Zigbee gateway): key
negotiation, Matter commands, state feedback, readings, disconnection and reconnection,
corrupted or fragmented frames, Matter endpoint created later, API, discovery (announcements in
TinyTuya's format), `devices.json` import, cloud import (signature compared with TinyTuya's),
web page, `toggle`. The **Build firmware** workflow runs them before each compilation, on the
source driver then on the solidified driver.

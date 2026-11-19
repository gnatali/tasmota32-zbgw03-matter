# Bug analysis: firmware and local Tuya driver (15 November 2026)

Review of this repository at commit `a5468f8`, looking for potential bugs, sorted by priority,
with improvement ideas. The companion report for the interface is in the TasmoFlow repository
(`docs/investigations/bug-analysis-2026-11.md`).

Goal of the project, used to rank the findings: a small Tasmota gateway that runs a small home
automation setup with no cloud dependency (Tuya or other) and that keeps working without
internet access.

## Scope and method

- Read in full: `berry/tuya_local.be` (2,880 lines), the three patches, `platformio_override.ini`,
  `user_config_override.h`, the workflow, the test harness.
- Tasmota internals were checked in its source at the workflow's `TASMOTA_REF` (`43d9409`), not
  assumed. The files are named in each finding.
- The test bench was built and run here: **27 of 27 scenarios pass** on the source driver and on
  the solidified driver. The same bench was then used to reproduce findings F1, F2 and F3
  (commands and outputs below). Nothing was tried on the real gateway.
- No fix was made: this report only describes. No real key or id is in the repository (the
  `key` and `secret` values found are the fake ones of the tests and the documentation).

Priorities: **P1** breaks a core function in normal use; **P2** wrong behaviour or loss of
function in a plausible situation; **P3** robustness, rare cases; **P4** minor.

## Summary

| Id | Priority | Finding | Status |
| --- | --- | --- | --- |
| F1 | P1 | After 24.9 days of uptime, a driver start or a `tuya.json` reload connects to no device; discovery and cloud import stall too | Reproduced on the bench |
| F2 | P2 | One invalid entry in `tuya.json` silently drops every device after it; `TuyaAdd` and the web page accept such an entry and answer "saved" | Reproduced on the bench |
| F3 | P2 | A Matter command to a disconnected device is dropped and the Matter endpoint keeps the state that was never applied | Reproduced on the bench |
| F4 | P3 | `tuya.json` is rewritten in place: a power cut during the write leaves a truncated file that is loaded as a shorter device list | Read in the code |
| F5 | P3 | Connections and disconnections are not published: rules, TasmoFlow and Matter cannot know that a device is offline | Read in the code |
| F6 | P3 | A frame over 4,096 bytes closes the connection, and it will again at every reconnection | Read in the code |
| F7 | P4 | DPs that are not kept in RAM are published as "changed" every time the device repeats them | Read in the code |
| F8 | P4 | Editing a device can create a second device with the same name or id | Read in the code |
| F9 | P4 | Device names, labels and units are written unescaped in the main page; the edit link is not URL-encoded | Read in the code |
| F10 | P4 | A device id with an upper-case letter cannot be addressed by id (`TuyaSend`, `TuyaStatus`) | Read in the code |

## Findings

### F1 (P1): no connection after 24.9 days of uptime

Berry integers are 32-bit signed on the ESP32 (`BE_INTGER_TYPE 1`,
`lib/libesp32/berry/default/berry_conf.h`) and `tasmota.millis()` pushes the unsigned counter
into one (`l_millis`, `xdrv_52_3_berry_tasmota.ino`). It is therefore **negative from 2^31 ms,
24.86 days after boot, until 49.71 days**, then positive again, and so on.

The driver compares absolute values in three places where the timer starts at 0:

| Where | Code | Effect while `millis()` is negative |
| --- | --- | --- |
| `TuyaDevice.init` line 510, `loop` line 566 | `t_retry = 0`, `if now >= self.t_retry  self.connect()` | A new `TuyaDevice` never connects |
| `TuyaScan.init` line 877, `loop` line 895 | `t_req = 0`, `if now >= self.t_req` | The discovery never sends its request: 3.5 devices are not found |
| `start_cloud` line 2487, `every_50ms` line 2685 | `cloud_t = 0`, `if ... now >= self.cloud_t` | The cloud import never runs and stays "already running" until a restart |

Every reload creates new `TuyaDevice` objects (`load_config`): `TuyaReload`, saving, deleting,
enabling or disabling a device or a binding (web page, commands, and through them TasmoFlow), an
import, or `TuyaEnable 1`. Done between day 24.86 and day 49.71, any of them leaves **all Tuya
devices disconnected until the gateway restarts**, with no error in the log. Devices that were
already connected before day 24.86 are not affected (the other timers use differences, which
survive the wrap), which makes the fault look random.

Reproduced on the bench, same `tuya.json` (one 3.3 device), only the harness's initial
`millis()` changed:

```
== millis positive (uptime 100 s)
LOG 2 TUY: 1 device(s), 1 Matter endpoint(s)
CONNECT 10.0.0.50 6668
RESP {"TuyaScan":"discovery started for 5 s"}
UDPTX 255.255.255.255 7000 00006699...
== millis negative (uptime 30 days: 2592000000 ms is -1702967296 in 32 bits)
LOG 2 TUY: 1 device(s), 1 Matter endpoint(s)
RESP {"TuyaScan":"discovery started for 5 s"}
```

No `CONNECT` and no `UDPTX` in the second run.

Fix: never compare two absolute `millis()` values. Use `tasmota.time_reached(t)` with
`t = tasmota.millis(delay)` (Tasmota's own pattern, used by Matter; `l_timereached` in the same
file), and start each timer from `tasmota.millis()` instead of 0. A related, much rarer case
goes away with the same change: a `t_retry` that falls in the last 50 ms before the wrap is
never reached. Test: a harness line that sets `tasmota.now` (for instance `MILLIS <value>`) and
a scenario that starts, reloads, scans and imports with a negative clock, then across the wrap.

### F2 (P2): one invalid entry drops every device after it

`load_config` (line 2637) builds each `TuyaDevice` inside the callback of
`TuyaImport.each_object`. An exception in one entry leaves the callback, `each_object` closes the
file and raises again, and `load_config` logs `cannot read /tuya.json` and returns: the devices
read so far are kept, **all the following ones are skipped**. Entries that raise: a sub-device
without `cid` (`str(c["cid"])`, line 504), a `sensors` value that is not a list (line 436), a
`key` that is not a string (line 499), a `matter` item that is not a map.

Nothing prevents saving such an entry: `save_device` (line 2140) only checks `name`, `id` and
the key's presence, and it is the path of both `TuyaAdd` and the web page's JSON editor, where
a typing mistake is likely. The answer says the save worked.

Reproduced on the bench (two valid lamps configured, then two `TuyaAdd`):

```
CMD TuyaAdd {"name":"Pince",...,"sensors":{"Puissance":19}}
LOG 1 TUY: cannot read /tuya.json: value 'int' does not support subscriptable
RESP {"TuyaAdd":"Pince"}
CMD TuyaAdd {"name":"Lampe C",...}          (valid)
LOG 1 TUY: cannot read /tuya.json: value 'int' does not support subscriptable
RESP {"TuyaAdd":"Lampe C"}
RESP {"TuyaStatus":{"Lampe B":{...},"Lampe A":{...}}}
```

`Lampe C` is in the file and never loaded. With the invalid entry first in the file, no device
at all is loaded.

Fix: a `try` around each entry in `load_config` (log the device's name and the error, go on
with the next one), and a validation in `save_device` before writing (types of `key`, `ip`,
`matter`, `sensors`, `children`; `cid` of each child), so that the error reaches the person who
typed it. Test: a scenario with an invalid entry in the middle of the file.

### F3 (P2): a Matter command to a disconnected device leaves Matter with a wrong state

`on_matter` (line 2712) ignores the result of `set_dps`, which returns `false` when the device
is not connected (line 639: `command ignored`). Tasmota's virtual endpoint has already taken
the value the controller asked for, so Google Home shows the lamp on while nothing was sent.
The difference then stays: when the device reconnects, its status equals what the driver
already knew, `TuyaNode.update` sees no change and sends no `MtrUpdate`.

Reproduced on the bench (device configured, not connected):

```
MTR {"ep1":{"Ep":1,"Name":"Porche","Power":1}}
LOG 2 TUY: Lampe A not connected, command ignored
```

No `MtrUpdate` follows.

Fix, smallest first: when `set_dps` returns `false`, push the binding's real state back
(`b.push(b.node.dps)`), so that the endpoint returns to what the device really is. Better for
the user: keep the last command of each DP for a few seconds and send it when the device is
`READY` again (lamps cut at the wall switch reconnect in a few seconds). `TuyaSend` already
answers `Device not connected`; a rule gets no second chance either, the same short queue would
serve both.

### F4 (P3): a power cut while `tuya.json` is written

`write_conf` (line 2077) copies the file to `.bak`, then rewrites `/tuya.json` in place, entry by
entry. Errors are handled well (restore from the `.bak`, bench scenario 26). A power cut or a
crash in the middle is not: the file stays truncated. At the next boot `each_object` loads the
complete entries and ignores the rest, so the driver runs with a shorter device list and says
nothing. `read_conf` does refuse a truncated file (`not valid JSON: not modified`), which
protects the `.bak`, but the repair is manual.

Fix: write `/tuya.json.new`, close it, then rename (`path.rename`, as TasmoFlow's `tf_update.be`
does for the `.tapp`), which LittleFS does atomically. At start, a file that does not end with
its closing bracket could be replaced by the `.bak` with a log line.

### F5 (P3): connection state is not published

`publish_result` is only called for DP changes (line 461) and for the end of background
operations. Nothing tells the rest of the system that a device connected or disconnected:

- a rule cannot react to a device going offline;
- TasmoFlow shows a device as connected until someone presses Refresh (it only learns
  `connected: true` from DP events);
- Matter endpoints stay reachable for a device that is gone.

Fix: publish `{"Tuya":{"Name":"...","Connected":false}}` from `close()` and `on_ready()` (only
on a change, to spare MQTT). TasmoFlow can then update its cards from the same event stream.

### F6 (P3): a frame over 4,096 bytes

`parse` (line 727) closes the connection on a frame longer than 4,096 bytes
(`invalid frame`). A device or a Tuya gateway whose status answer is larger (many DPs holding
long strings, scenes for instance) would be disconnected at every query, with the retry delay
growing to 60 s, and would never work. Not seen on the 12 current devices. If it happens: skip
the oversized frame (count down its bytes without storing them) instead of closing.

### F7 to F10 (P4)

- **F7**: `TuyaNode.update` (line 453) compares each received DP with the stored value, but DPs
  outside `keep`, the bindings and the sensors are never stored, so they are "changed" each time
  the device sends them again. A rule on such a DP fires on every report, not on a change, and
  each one costs a `RESULT` message (the tracking file already lists "limit `publish_result`").
  A one-entry hash per node, or documenting that `keep` is needed for change detection, would
  settle it.
- **F8**: `save_device` with a `ref` (editing from the web page) replaces the entry without
  checking that the new `name` or `id` is not used by another device. `find_node` then always
  returns the first of the two.
- **F9**: `web_sensor` (line 2873) writes `n.name`, the sensor label and the unit in the main
  page without `html_escape`; the edit link of the device list (`/tuya?edit=<id>`, line 1544) is
  HTML-escaped but not URL-encoded. Only the administrator can write these values, so the risk
  is a broken page, not an attack.
- **F10**: `find_node` (line 2733) and `cmd_status` lower-case the argument and compare it with
  `n.id` as stored. Tuya ids are lower case in practice; comparing `string.tolower(n.id)` costs
  nothing.

## Checked and found sound

Worth knowing so that it is not checked again: frame parsing bounds and resynchronisation
(`parse`, `decode`, `decode_udp`), HMAC, CRC and GCM tag checks before any use of the payload,
session key negotiation against TinyTuya's, partial TCP writes, the rollback of `write_conf` on
an error, chunked reading of `tuya.json` and `devices.json`, key masking in `TuyaConfig` and in
the web editor, the cloud credentials kept out of `tuya.json`, the memory guards, the three
patches (the AES-GCM one keeps the 32-byte behaviour unchanged).

Not validated on a real device according to the tracking file: **protocol 3.4** (Pergola 1 and 2
are still disabled). The bench covers it against TinyTuya only.

## To check on the gateway for the "no internet" goal

- **Clock without NTP.** Tuya commands carry `"t"` from `tasmota.rtc()['utc']` (`time_str`,
  line 618). Without internet the clock is not set after a power cut. Devices are expected to
  ignore `t`, as with TinyTuya, but this was never tried: unplug the WAN, restart the gateway,
  send `TuyaSend` to a 3.3, a 3.5 device and a sub-device.
- **Start without internet**: `start_wait` only needs a local IP address, Zigbee and Matter, so
  the driver should start. To confirm in the same test.
- The cloud import refuses to run without a synchronised clock (`now_ms`), which is right: it
  is a set-up tool, not needed afterwards.

## Improvement ideas

Ordered by what they bring to a cloud-free setup that runs unattended.

1. **Rule-friendly Tuya events.** Today a Tasmota rule cannot wait for "DP 1 of the device
   Lampe": the event is `{"Tuya":{"Name":...,"Dps":{...}}}` and a trigger cannot test `Name` and
   a DP together, so Tuya triggers need Berry (noted in TasmoFlow's tracking). Publishing a second
   form keyed by the device, `{"TuyaReceived":{"<id or name>":{"1":true}}}`, like Zigbee's
   `ZbReceived#<device>#<attribute>`, would let `Rule1` to `Rule3` and TasmoFlow's sentence
   editor use Tuya devices as triggers with no Berry code.
2. **Short command queue** for a device that is reconnecting (see F3), and the real state pushed
   back to Matter when a command cannot be sent.
3. **Connection events** (F5), then Matter reachability from them if Tasmota's virtual endpoints
   allow it.
4. **`TuyaConfig <device>` without loading the whole file**: it calls `read_conf` (the whole
   `tuya.json`, 30 KB of free heap needed) even for one device, while `TuyaWeb.edit` already
   finds one entry with `each_device`. TasmoFlow could then read the configuration device by
   device and stop depending on free memory for its controls (its report, finding T4).
5. **Tests on pull requests.** The workflow only runs on a tag or by hand, so the bench never
   runs on a PR. A second, light job (`pull_request`, sparse Tasmota checkout, `run_tests.sh`,
   about a minute, no PlatformIO) would catch regressions before the merge.
6. **A wrap-around scenario in the bench** (F1), and one with an invalid entry (F2): both are
   cheap now that the harness can be given a clock.
7. **Periodic status query** (every few minutes) for devices that do not push every change, and
   a "last seen" age for sub-devices of a Tuya gateway: `seen` is stored (line 458) but never
   shown or used.
8. **Devices that answer the status query with an error** (22-character ids, TinyTuya's
   "device22"): they need the query sent as a control frame listing the DPs. Not needed for the
   current devices, worth a line in the user guide until supported.
9. **Reproducible build**: pin `platformio` and `tinytuya` versions in the workflow
   (`pip install platformio==... tinytuya==...`); the Tasmota commit is already pinned.
10. **Security note in the user guide**: `/tuya.json`, its `.bak` and `/tuya_cloud.json` hold
    the local keys and the cloud secret in clear text and can be downloaded with Tasmota's file
    manager. Setting `WebPassword` is what protects them (and TasmoFlow's token page).

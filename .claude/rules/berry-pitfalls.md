---
paths:
  - "berry/**"
  - "**/*.be"
---
# Known pitfalls (Berry under Tasmota)

- Tasmota compiles in **strict mode** (`comp_set_strict`): inside a function or a block,
  assigning to an undeclared name is an error (`strict: no global 'x', did you mean 'var x'?`).
  Declare with `var`, and create a global from a function with `import global` then
  `global.x = ...`. At the top level of the loaded file, `x = ...` is still allowed and creates
  a global. The test bench compiles the source driver in strict mode.
- **32-bit** integers and **single-precision** floats: an energy counter divided as a float
  loses decimals. The driver formats measurements as exact decimals from the integer
  (`TuyaLocal.scaled`). `json.load` returns **`nil` for the whole document** as soon as an
  integer exceeds 2,147,483,647 (e.g. `"t"` in ms in Tuya cloud responses):
  `TuyaCloud.quote_big` quotes them first. The test bench has the same limit.
- `bytes .. bytes` **appends in place** and modifies the left operand; `+` creates a new object.
- In an f-string, no `!=` or `=` operator inside braces (`{x=}` is for debugging): compute the
  value in a variable first.
- `crypto.AES_GCM(key, iv [, aad])`: 16- or 32-byte key **thanks to this repository's patch**;
  a single `encrypt` or `decrypt` per instance in the test module.
- `tcpclientasync.connected()` returns `nil` while connecting, then `true` or `false`.
- **Solidified driver** (`custom_berry_solidify`, classes in flash):
  - no top-level code outside the classes: solidification runs the file (without `tasmota`),
    and the firmware's Berry init code instantiates the driver (`global.tuya_local =
    TuyaLocal()`, `patches/tuya-local-autostart.patch`, under the `USE_TUYA_LOCAL` build flag,
    like Matter's `matter_device`);
  - `import string` / `json` / `crypto` **in every method** that uses them: a top-level import
    does not exist in the firmware;
  - a solidified class is **read-only**: no write to a `static var`
    (`attribute_error ... cannot assign to static attribute`), constants only;
  - one `#@ solidify:Class,weak` directive per class (`weak`: strings outside the global
    table). Tasmota's script only registered the first one: patch
    `patches/berry-solidify-all-classes.patch`.
- `webserver.on()` **crashes the ESP32** if the web server is not started yet: the driver only
  calls it itself if `webserver.state() > 0` (Tasmota does not call `web_add_handler()` for a
  driver added after the server started).
- **Web page**: Tasmota's container is an `inline-block` at least 340 px wide that grows to its
  widest content. Text in `<p style='width:320px;'>` (`TuyaWeb.p`), one field per
  `<p><b>Label</b><br><input></p>` block, never several fields side by side; check the width on
  a desktop screen (screenshot with Tasmota's CSS).
- File larger than the free RAM (tinytuya's `devices.json`): read it in chunks
  (`readbytes(512)`, `TuyaImport.each_object`), never `read()` in one go. The same goes for
  `/tuya.json` once imported (~1 KB per device): `json.load` of a whole file costs ~3 times its
  size while alive. Read it entry by entry (`each_device()`), load it whole (`read_conf()`)
  only to modify it, and call `tasmota.gc()` after a web page: Berry only collects garbage
  when it needs to, and the page's garbage pushed the gateway to allocation failures.
- **Start at boot**: `TuyaLocal.init()` runs in Berry's init code, before the network, Zigbee and
  Matter: it must stay light (no file, no connection, no `persist`). The real start is in
  `every_second()` (`start_wait()`: enabled, Zigbee started, network, Matter started, memory).
  Loading the driver while Zigbee and Matter start crashed the ESP32 (no PSRAM); after 4 quick
  crashes, the boot-loop protection starts **without Berry, hence without Matter**, and
  **disables all rules**. `TuyaEnable 0` (or `tuya_local` set to `false` in `_persist.json`)
  keeps the driver stopped.
- Matter disabled (`SetOption151 0`): `matter_device` still exists, without configuration
  (`plugins_config` is `nil`) and without the `MtrUpdate` command. Matter started:
  `matter_device.udp_server` is set; `matter_device.started` is declared but **never set**
  (stays `nil`). Check such Tasmota internals in its source before relying on them, and make
  the mocks behave like the source, not like the name suggests.
- **Writing a big JSON file**: never `open(f, "w")` before the content exists in memory, and never
  `json.dump` the whole file as one string (needs ~ the file size again; the ESP32 ran out of Berry
  heap and left `tuya.json` empty). Write entry by entry (`TuyaLocal.write_conf`), keep the
  previous version in a `.bak` (never from an empty file) and restore it on any error. The bench
  injects a failure with `WRITEFAIL` (an object whose `tojson()` raises).
- **Memory guards between steps**: free heap read right after a request includes uncollected
  garbage (32 KB read with 63 KB free at rest): `tasmota.gc()` first, and postpone rather than abort.

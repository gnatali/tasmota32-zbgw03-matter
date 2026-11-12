---
paths:
  - "berry/**"
---
# Tuya driver tests

```bash
# Tasmota at the workflow's commit (a partial clone is enough)
git clone --filter=blob:none --no-checkout https://github.com/arendst/Tasmota.git tasmota && cd tasmota
git sparse-checkout set --no-cone 'lib/libesp32/berry/*' 'lib/libesp32/re1.5/*' \
  'lib/libesp32/berry_mapping/*' 'lib/libesp32/berry_int64/*' 'lib/libesp32/berry_custom/*' \
  'lib/lib_ssl/bearssl-esp8266/*'
git checkout <workflow TASMOTA_REF> && cd ..
bash berry/test/run_tests.sh tasmota     # writes /tuya.json(.bak), /devices.json, /tuya_cloud.json: container or CI
```

- `run_tests.sh` builds Tasmota's Berry interpreter with `testcrypto.c` (AES-CBC, AES-GCM with
  AAD, HMAC-SHA256, MD5 on Tasmota's BearSSL). `crypto.be` mirrors the API of Tasmota's
  `crypto` module, `webserver.be` the `webserver` module, and `harness.be` mocks `tasmota`,
  `tcpclientasync`, `udp`, `webclient` (cloud), `zigbee`, `matter_device` and (`persist.be`)
  `persist`, driven line by line by
  `test_tuya_local.py`. The test writes `/tuya.json`, `/tuya.json.bak`, `/devices.json` and
  `/tuya_cloud.json`.
- The 28 scenarios (0 to 27) run **twice**: source driver (compiled by the harness in strict mode), then
  the **solidified** driver as in the build (Python port of Berry `berry_port`, `coc` string
  table, read-only native classes linked into a second interpreter). A solidification error or
  a write to a `static var` shows up there without waiting for the PlatformIO build. The
  harness instantiates `TuyaLocal()` like the firmware's Berry init code; it starts disabled,
  with Zigbee not started (`TuyaEnable 1`, `ZIGBEE 1`, `SECOND` start it).
- The fake devices (`fake_tuya.py`) are built on **TinyTuya** and were validated against the
  real TinyTuya client. It is the protocol reference: when in doubt, compare with TinyTuya's
  source (`tinytuya/core/XenonDevice.py`, `message_helper.py`). UDP announcements are produced
  by `udp_broadcast()` and checked with TinyTuya's `decrypt_udp()`; the cloud signature is
  compared with `tinytuya.Cloud`'s (mocked requests).
- Integers are 32-bit in the bench too (as on the ESP32): real cloud responses (`"t"` in ms)
  must be part of the mocked responses.
- Every driver change comes with a test scenario. The workflow runs the tests before compiling.

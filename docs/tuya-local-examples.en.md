# Local Tuya driver: command and event examples

*Version française : [tuya-local-examples.fr.md](tuya-local-examples.fr.md)*

Usage examples for the ZB-GW03 local Tuya driver: commands, responses, events, rules and Berry
scripts. Ids, addresses and responses are made up but use the driver's exact format; no key
appears (the driver replaces them with `***`). Details: [tuya-local.fr.md](tuya-local.fr.md)
(French) and [tuya-local-dev.en.md](tuya-local-dev.en.md).

The driver's messages are in French; their meaning is given in the tables below. Device names
are those of the example installation (they are user-defined).

Devices used in the examples: `Ventilateur` (fan, 3.5; DP 60 on/off, 62 speed, 20 light),
`Récepteur radio` (radio receiver, 3.5; DP 1 to 4), `Entrée-Porche` (porch bulb, 3.3; DP 20 to
23), Zigbee button SNZB-01P `0x922D` on the ZB-GW03.

## Contents

1. [Where to send commands](#1-where-to-send-commands)
2. [Reading state](#2-reading-state)
3. [Controlling a device](#3-controlling-a-device)
4. [Adding, editing, deleting](#4-adding-editing-deleting)
5. [Discovery and import](#5-discovery-and-import)
6. [Matter](#6-matter)
7. [Events](#7-events)
8. [Console messages](#8-console-messages)
9. [Tasmota rules](#9-tasmota-rules)
10. [Berry scripts](#10-berry-scripts)

## 1. Where to send commands

| Channel | Send | Response |
|---|---|---|
| Web console | `TuyaStatus` | `RSL: RESULT = {"TuyaStatus":{...}}` |
| HTTP | `http://192.168.1.13/cm?cmnd=TuyaStatus` | JSON body `{"TuyaStatus":{...}}` |
| MQTT | topic `cmnd/<topic>/TuyaStatus`, empty payload | on `stat/<topic>/RESULT` |

Over HTTP, encode spaces and JSON (`curl -G --data-urlencode`), and add
`user=admin&password=...` if a web password is set (`WebPassword`):

```bash
curl "http://192.168.1.13/cm?cmnd=TuyaSend%20Ventilateur,60,true"
curl -G "http://192.168.1.13/cm" --data-urlencode "user=admin" --data-urlencode "password=xxx" \
     --data-urlencode 'cmnd=TuyaStatus Entrée-Porche'
```

Over MQTT (`mosquitto` for instance):

```bash
mosquitto_sub -h broker -t 'stat/<topic>/RESULT' -v &
mosquitto_pub -h broker -t 'cmnd/<topic>/TuyaSend' -m 'Ventilateur,62,3'
```

## 2. Reading state

**State of all devices**:

```
TuyaStatus
```
```json
{"TuyaStatus":{
  "Ventilateur":{"Connected":true,"Ip":"192.168.1.20","Version":"3.5","Dps":{"20":false,"60":true,"62":3,"63":"forward"}},
  "Récepteur radio":{"Connected":true,"Ip":"192.168.1.23","Version":"3.5","Dps":{"1":false,"2":false,"3":false,"4":false}},
  "Entrée-Porche":{"Connected":false,"Ip":"192.168.1.174","Version":"3.3","Dps":{}}}}
```

**A single device** (case-insensitive name, or id): `TuyaStatus entrée-porche`. Unknown:
`{"TuyaStatus":"Appareil inconnu"}` (unknown device).

**Configuration without keys**: `TuyaConfig`, or `TuyaConfig Ventilateur` for one device:

```json
{"TuyaConfig":{"name":"Ventilateur","id":"00000000000000fan001","key":"***","ip":"192.168.1.20",
 "version":"3.5","matter":[{"ep":"Ventilateur","type":"fan","dp":60,"dp_speed":62,"speed_min":1,"speed_max":6},
                           {"ep":"Lumière ventilateur","type":"light0","dp":20}]}}
```

## 3. Controlling a device

| Command | Effect |
|---|---|
| `TuyaSend Ventilateur,60,true` | on |
| `TuyaSend Ventilateur,62,3` | speed 3 |
| `TuyaSend Ventilateur,63,"reverse"` | text value (JSON) |
| `TuyaSend Ventilateur,20,toggle` | toggles the fan light |
| `TuyaSend Lampe,switch_led,true` | by DP code (imported device, with a `codes` table) |
| `TuyaSend Lampe,bright_value_v2,500` | brightness by code |

Responses: `{"TuyaSend":"Done"}` if the command was sent, otherwise:

| Response | Meaning |
|---|---|
| `Appareil inconnu` | no device with that name or id |
| `Appareil non connecte` | device offline (the command is not sent) |
| `DP inconnu : xxx` | code missing from the device's `codes` table |
| `toggle : etat du DP inconnu` | the device has not sent this DP yet |
| `toggle : DP non booleen` | `toggle` on a value that is not true/false |
| `Syntaxe : TuyaSend <appareil>,<dp ou code>,<valeur\|toggle>` | missing arguments (syntax) |

## 4. Adding, editing, deleting

**Add** a tunable-white bulb (16-character local key):

```
TuyaAdd {"name":"Lampe bureau","id":"00000000000000lamp01","key":"<local key>","ip":"192.168.1.40","version":"3.3","matter":[{"ep":"Lampe bureau","type":"light2","dp":20,"dp_mode":21,"dp_bri":22,"dp_ct":23}]}
```
```json
{"TuyaAdd":"Lampe bureau"}
```

**Edit** without typing the key again: `"key":"***"` (or no `key`) keeps the stored key.

```
TuyaAdd {"name":"Lampe bureau","id":"00000000000000lamp01","key":"***","ip":"192.168.1.41","version":"3.3","matter":[{"ep":"Lampe bureau","type":"light2","dp":20,"dp_mode":21,"dp_bri":22,"dp_ct":23}]}
```

**Delete**: `TuyaDel Lampe bureau` → `{"TuyaDel":"Lampe bureau"}`.
**Reload** a hand-edited `tuya.json`: `TuyaReload` → `{"TuyaReload":"Done"}`.

Each write keeps the previous version in `/tuya.json.bak`. Possible errors:
`{"TuyaAdd":{"Error":"name et id requis"}}` (name and id required), `"cle locale (key) requise"`
(local key required), `"nom ou id deja utilise"` (name or id already used),
`"/tuya.json n'est pas un JSON valide : non modifie"` (invalid JSON, file left untouched).

## 5. Discovery and import

**Discover** devices on the network (20 s by default, 60 at most):

```
TuyaScan 30
```
```json
{"TuyaScan":"recherche lancee pour 30 s"}
```

At the end, an event (MQTT `stat/<topic>/RESULT` and rules):

```json
{"TuyaScan":{"Devices":[
  {"id":"00000000000000fan001","ip":"192.168.1.20","version":"3.5","product_key":"keyfan0000000000"},
  {"id":"0000000000000porch01","ip":"192.168.1.174","version":"3.3","product_key":"keyporch00000000"}]}}
```

**Import** the `devices.json` produced by `tinytuya wizard` (uploaded through Tools → Manage File
system):

| Command | Imported devices |
|---|---|
| `TuyaImport` | those of the last discovery or already configured, from `/devices.json` |
| `TuyaImport all` | all of them |
| `TuyaImport 00000000000000fan001,0000000000000porch01` | those ones |
| `TuyaImport /other.json all` | all of them, from another file |

```json
{"TuyaImport":{"Added":["Lampe bureau"],"Updated":["Ventilateur","Entrée-Porche"],"Skipped":[]}}
```

**Import from the Tuya cloud** (Tuya IoT project: Access ID and Access Secret; devices of the
last discovery, or a `devices` list). The web console logs the command with the secret: prefer
the **Tuya local** page, or MQTT / HTTP.

```
TuyaCloud {"region":"eu","id":"<Access ID>","secret":"<Access Secret>"}
TuyaCloud {"region":"eu","id":"<Access ID>","secret":"<Access Secret>","devices":["00000000000000lamp01"]}
```
```json
{"TuyaCloud":"import cloud lance pour 3 appareil(s)"}
```

One request per second, then the final event:

```json
{"TuyaCloud":{"Added":["Lampe bureau"],"Updated":["Ventilateur"],"Skipped":[]}}
{"TuyaCloud":{"Error":"cloud Tuya : sign invalid"}}
```

Other errors: `"memoire libre insuffisante : 30 Ko, 35 Ko necessaires"` (not enough free
memory), `"heure non synchronisee (NTP)"` (time not synchronised),
`"region inconnue (eu, we, us, ue, cn, in, sg)"` (unknown region),
`"aucun appareil : lancer d'abord une recherche (TuyaScan)"` (no device: run a discovery first),
`"cloud Tuya : HTTP 404"`.

## 6. Matter

**Create the missing Matter endpoints** (one per `matter` binding, of the matching type):

```
TuyaMatter
```
```json
{"TuyaMatter":{"Added":["Lampe bureau"],"Restart":"Restart 1 pour que Google Home les voie"}}
```

Then `Restart 1`: without a restart, Google Home shows the new devices offline.

**What the driver does**: a Google Home command arrives as an `MtrReceived` event and goes to
the Tuya device (log `TUY: Matter 'Ventilateur' -> Ventilateur {"60":true,"62":3}`); a change on
the device goes to Matter with `MtrUpdate {"Name":"Ventilateur","FanSpeed":50}`.

## 7. Events

**Device state change** (MQTT `stat/<topic>/RESULT`, console `RSL: RESULT = ...`, rules): only
the DPs that changed, or the whole state on connection.

```json
{"Tuya":{"Name":"Ventilateur","Dps":{"62":3}}}
{"Tuya":{"Name":"Entrée-Porche","Dps":{"20":true,"21":"white","22":1000,"23":0}}}
```

**Readings** (devices with `sensors`, e.g. a clamp meter), in the `tele/<topic>/SENSOR` message
and on the main page:

```json
{"Time":"2026-11-07T18:30:00","Tuya":{"Pince":{"Energie":22687.03,"Puissance":592,"Tension A":235.0}}}
```

**End of operations**: `{"TuyaScan":{"Devices":[...]}}` and `{"TuyaCloud":{...}}` (see § 5).

## 8. Console messages

| Message | Meaning |
|---|---|
| `TUY: demarrage du driver, memoire libre 73 Ko` | `autoexec.be` starts the driver (free memory) |
| `TUY: 3 appareil(s), 5 endpoint(s) Matter` | configuration loaded |
| `TUY: Ventilateur (192.168.1.20) connecte, protocole 3.5` | connected |
| `TUY: Ventilateur (192.168.1.20) deconnecte : plus de reponse` | device silent for 35 s; automatic reconnection |
| `TUY: Ventilateur non connecte, commande ignoree` | command while disconnected (ignored) |
| `TUY: endpoint Matter 'Lampe' : Invalid Device (nouvel essai toutes les 30 s)` | Matter endpoint missing (different name or not created yet; retried every 30 s) |
| `TUY: endpoint Matter 'Lampe' disponible, etat envoye` | the endpoint accepts, state sent |
| `TUY: appareil incomplet ignore : Pergola 1` | entry without `ip`, `key` or `id` (skipped) |
| `TUY: TuyaScan {"Devices":[...]}` | end of discovery |
| `TUY: import : objet JSON trop gros, ignore` | entry over 8 KB in `devices.json` (skipped) |

## 9. Tasmota rules

**Zigbee SNZB-01P button → Tuya devices** (`Power` 2: single press, 1: double, 0: long).
`Rule1` stays free for the virtual Matter button; both rules fire:

```
Rule2 on ZbReceived#0x922D#Power=2 do TuyaSend Entrée-Porche,20,toggle endon on ZbReceived#0x922D#Power=1 do TuyaSend Ventilateur,20,toggle endon on ZbReceived#0x922D#Power=0 do TuyaSend Récepteur radio,1,toggle endon
Rule2 1
```

**Two-position Zigbee switch**:

```
Rule2 on ZbReceived#0x1234#Power=1 do TuyaSend Entrée-Porche,20,true endon on ZbReceived#0x1234#Power=0 do TuyaSend Entrée-Porche,20,false endon
```

**React to a Tuya device**: `Tuya#Dps#<dp>` fires for **any** device that sends this DP (the
rule does not see the name); keep it for a DP that only one device has:

```
Rule3 on Tuya#Dps#62 do Publish stat/ventilateur/vitesse %value% endon
Rule3 1
```

**Every evening at 11 pm, turn the fan off** (independent of Google Home and the internet):

```
Rule3 on Time#Minute=1380 do TuyaSend Ventilateur,60,false endon
```

## 10. Berry scripts

**Complete `autoexec.be`**: delayed driver start, then Zigbee ↔ Tuya links.

```berry
def tuya_start()
  import global
  var free = tasmota.memory()['heap_free']
  if free < 60
    tasmota.log(f"TUY: driver non demarre, memoire libre insuffisante ({free} Ko)", 2)
    return
  end
  tasmota.log(f"TUY: demarrage du driver, memoire libre {free} Ko", 2)
  if !global.contains("TuyaLocal")  load("tuya_local.be")  end
  global.tuya_local = TuyaLocal()

  # single press on button 0x922D: toggle the Entree-Porche light
  tasmota.add_rule("ZbReceived#0x922D#Power=2", def (v)
    tasmota.cmd("TuyaSend Entrée-Porche,20,toggle")
  end)

  # Entree-Porche switched on or off: the Zigbee light "Salon" follows
  tasmota.add_rule("Tuya", def (v)
    if v.find("Name") == "Entrée-Porche" && v["Dps"].contains("20")
      tasmota.cmd('ZbSend {"Device":"Salon","Send":{"Power":' + (v["Dps"]["20"] ? "1" : "0") + '}}')
    end
  end)
end
tasmota.set_timer(30000, tuya_start)
```

Beware of loops: if the Zigbee light in turn controls Entrée-Porche, only relay when the state
differs.

**From the Berry console** (`Br ...`), the driver object is `tuya_local`:

```berry
Br tuya_local.find_node("Ventilateur").dps          # last known state
Br for d: tuya_local.devices  print(d.name, d.ip, d.state == d.ST_READY)  end
Br var n = tuya_local.find_node("Ventilateur")  n.conn.set_dps(n, {"60": true, "62": 2})
Br tuya_local.scan_result                            # result of the last discovery
```

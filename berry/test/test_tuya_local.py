"""End-to-end tests of the tuya_local.be driver against fake Tuya devices (fake_tuya.py).

Run: python3 test_tuya_local.py [path of the test berry interpreter]
The /tuya.json file is written for the test (fake configuration).
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fake_tuya import FakeDevice  # noqa: E402

BERRY = sys.argv[1] if len(sys.argv) > 1 else "berry"

K = {n: ("%016d" % i)[:16].replace("0", "k") for i, n in enumerate(
    ["fan", "clamp", "porch", "radio", "pergola", "gw"], start=1)}
K["fan"] = "Zq!(4.P;n+x-T]w~"   # special characters, like real keys (fake key)

CONFIG = {"devices": [
    {"name": "Ventilateur", "id": "fan000000000000000000", "key": K["fan"], "ip": "10.0.0.18", "version": "3.5",
     "matter": [{"ep": "Ventilateur", "type": "fan", "dp": 60, "dp_speed": 62, "speed_max": 6},
                {"ep": "Lumiere ventilateur", "type": "light0", "dp": 20}]},
    {"name": "Pince", "id": "clamp0000000000000000", "key": K["clamp"], "ip": "10.0.0.80", "version": "3.5",
     "sensors": {"Energie": [131, 100, "kWh"], "Puissance": [133, 1, "W"], "Tension A": [101, 10, "V"]}},
    {"name": "Entree-Porche", "id": "porch0000000000000000", "key": K["porch"], "ip": "10.0.0.174", "version": "3.3",
     "matter": [{"ep": "Porche", "type": "light2"}]},
    {"name": "Recepteur radio", "id": "radio0000000000000000", "key": K["radio"], "ip": "10.0.0.15", "version": "3.5",
     "matter": [{"ep": "Radio 1", "type": "relay", "dp": 1}, {"ep": "Radio 2", "type": "relay", "dp": 2}]},
    {"name": "Pergola 1", "id": "perg00000000000000000", "key": K["pergola"], "ip": "10.0.0.31", "version": "3.4",
     "matter": [{"ep": "Pergola 1", "type": "light3"}]},
    {"name": "Gateway", "id": "gw0000000000000000000", "key": K["gw"], "ip": "10.0.0.180", "version": "3.3",
     "children": [
         {"name": "Prise Lisseur", "id": "plug00000000000000000", "cid": "00158d0000000001",
          "matter": [{"ep": "Prise Lisseur", "type": "relay_power", "dp": 1,
                      "dp_power": 19, "div_power": 10, "dp_voltage": 20, "div_voltage": 10,
                      "dp_current": 18, "div_current": 1000}]},
         {"name": "Temperature SdB", "id": "temp00000000000000000", "cid": "00158d0000000002",
          "matter": [{"ep": "Temperature SdB", "type": "temp", "dp": 1, "div": 10},
                     {"ep": "Humidite SdB", "type": "humidity", "dp": 2, "div": 10}]}]},
]}

DEVS = {
    "10.0.0.18": FakeDevice("fan000000000000000000", K["fan"], 3.5,
                            {"20": True, "23": 0, "60": False, "62": 2, "63": "forward"}),
    "10.0.0.80": FakeDevice("clamp0000000000000000", K["clamp"], 3.5,
                            {"101": 2350, "131": 2268703, "133": 592}),
    "10.0.0.174": FakeDevice("porch0000000000000000", K["porch"], 3.3,
                             {"20": False, "21": "white", "22": 1000, "23": 0}),
    "10.0.0.15": FakeDevice("radio0000000000000000", K["radio"], 3.5,
                            {"1": False, "2": False, "3": False, "4": False}),
    "10.0.0.31": FakeDevice("perg00000000000000000", K["pergola"], 3.4,
                            {"20": True, "21": "white", "22": 500, "24": "000003e803e8"}),
    "10.0.0.180": FakeDevice("gw0000000000000000000", K["gw"], 3.3, children={
        "00158d0000000001": {"1": False, "18": 0, "19": 0, "20": 2310},
        "00158d0000000002": {"1": 215, "2": 560, "4": 100}}),
}


class Harness:
    def __init__(self):
        self.p = subprocess.Popen(["stdbuf", "-oL", BERRY, "harness.be"], cwd=HERE, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, bufsize=1)
        self.out = []
        self.read()   # output of the loading

    def read(self):
        lines = []
        while True:
            l = self.p.stdout.readline()
            if not l:
                raise RuntimeError("berry stopped:\n" + "\n".join(self.out[-30:] + lines))
            l = l.rstrip("\n")
            if l == "READY":
                break
            lines.append(l)
        self.out += lines
        return lines

    def send(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        return self.read()

    def pump(self, lines, rounds=6):
        """Forwards TX to the fake devices and returns their responses, until things settle."""
        allout = list(lines)
        pending = list(lines)
        for _ in range(rounds):
            new = []
            for l in pending:
                if l.startswith("CONNECT "):
                    ip = l.split()[1]
                    DEVS[ip].reset_session()
                    new += self.send("OPEN " + ip)
                elif l.startswith("TX "):
                    _, ip, hx = l.split(" ", 2)
                    for r in DEVS[ip].feed(bytes.fromhex(hx)):
                        new += self.send("RX %s %s" % (ip, r.hex()))
            if not new:
                # flush the pending partial writes
                new = self.send("ADV 50")
                if not any(x.startswith("TX ") for x in new):
                    allout += new
                    break
            allout += new
            pending = new
        return allout

    def close(self):
        self.p.stdin.write("END\n")
        self.p.stdin.flush()
        self.p.wait(5)


def struct_cmd(pkt):
    """Command of a 55AA or 6699 frame."""
    return int.from_bytes(pkt[10:14] if pkt[:4] == b"\0\0\x66\x99" else pkt[8:12], "big")


def tinytuya_sign(creds, url, hdr):
    """Signature computed by tinytuya.Cloud (mocked requests and time) for the same request."""
    import sys
    import tinytuya
    mod = sys.modules["tinytuya.Cloud"]
    seen = {}

    class R:
        status_code = 200
        content = b'{"success": true, "result": {"access_token": "tok123"}}'
        text = content.decode()
        def json(self):
            return {"success": True, "result": {"access_token": "tok123"}}

    class FakeRequests:
        @staticmethod
        def get(u, headers=None):
            seen["sign"] = headers["sign"]
            return R()
        Request = mod.requests.Request

    class FakeTime:
        @staticmethod
        def time():
            return int(hdr["t"]) / 1000.0
    real_req, real_time = mod.requests, mod.time
    mod.requests, mod.time = FakeRequests, FakeTime
    try:
        token = hdr.get("access_token")
        c = tinytuya.Cloud(apiRegion=creds["region"], apiKey=creds["id"], apiSecret=creds["secret"],
                           initial_token=token or "x")
        if token is None:
            c.token = None
            c._gettoken()
        else:
            path = url.split("/", 3)[3]
            c._tuyaplatform(path.split("/", 1)[1], ver=path.split("/", 1)[0])
    finally:
        mod.requests, mod.time = real_req, real_time
    return seen["sign"]


def page_btn(h):
    out = h.send("WEBBTN")
    return json.loads([l for l in out if l.startswith("PAGE ")][-1][5:]), out


def mtr_updates(lines):
    return [json.loads(l[len("CMD MtrUpdate "):]) for l in lines if l.startswith("CMD MtrUpdate ")]


def find(updates, name):
    r = {}
    for u in updates:
        if u.get("Name") == name:
            r.update(u)
    return r


def main():
    with open("/tuya.json", "w") as f:
        json.dump(CONFIG, f)
    h = Harness()
    ok = 0

    # 0. start at boot, like Matter: the firmware instantiates the driver, which does nothing
    #    until enabled, then waits for Zigbee; greyed-out main page button meanwhile
    def page(method, args):
        out = h.pump(h.send("HTTP %s /tuya %s" % (method, json.dumps(args))))
        return json.loads([l for l in out if l.startswith("PAGE ")][-1][5:]), out

    def resp(out, name):
        r = [l for l in out if l.startswith("RESP ")]
        assert r, out
        return json.loads(r[-1][5:])[name]
    out = h.send("ADV 3000")
    assert not [l for l in out if l.startswith(("CONNECT", "TX"))], out
    assert resp(h.send("CMD TuyaEnable"), "TuyaEnable") == {"Enabled": False, "State": "disabled"}
    assert not [l for l in h.send("SENSOR") if "Tuya Local" in l]           # disabled: no button
    html, _ = page("GET", {})
    assert "name='enable'><b>Tuya Local enable" in html and "Tuya Local is not running" in html, html
    out = h.send("CMD TuyaEnable 1")
    assert resp(out, "TuyaEnable") == {"Enabled": True, "State": "starting"}, out
    assert 'PERSIST {"tuya_local":true}' in out, out
    out = h.send("ADV 3000")                                               # Zigbee not started yet
    assert not [l for l in out if l.startswith(("CONNECT", "TX"))], out
    assert any("TUY: waiting for Zigbee" in l for l in out), out
    web = [l for l in h.send("SENSOR") if "Tuya Local" in l]
    assert web and "<button disabled" in web[-1] and "waiting for Zigbee" in web[-1], web
    assert "&#x23F8;" in page("GET", {})[0]                                # devices: driver not running
    out = h.send("NEWDRV")                                                 # old autoexec.be lines
    assert any("remove the tuya_local lines from autoexec.be" in l for l in out), out
    nd = [l for l in out if l.startswith("NEWDRV ")][0].split()
    assert nd[1] == "true" and nd[2] == "1", nd                            # inert, not registered
    h.send("ZIGBEE 1")
    h.send("MATTERUDP 0")                                                  # Matter enabled, not started
    out = h.send("SECOND")
    assert any("TUY: waiting for Matter" in l for l in out), out
    assert not [l for l in out if l.startswith(("CONNECT", "TX"))], out
    assert resp(h.send("CMD TuyaEnable"), "TuyaEnable")["State"] == "waiting for Matter"
    h.send("MATTERUDP 1")                                                  # UDP server up: started
    ok += 1
    print("OK 0 start at boot: disabled, enabled, waiting for Zigbee (greyed button) then Matter, second instance inert")

    # 1. start (Zigbee ready): connection, negotiation and initial state of all devices
    out = h.pump(h.send("SECOND"))                                         # starts: tuya.json loaded
    assert any("TUY: starting, free memory" in l for l in out), out
    out += h.pump(h.send("ADV 50"))
    errs = [l for l in out if l.startswith("LOG 1") or " error: " in l]
    assert not errs, errs
    up = mtr_updates(out)
    assert find(up, "Ventilateur") == {"Name": "Ventilateur", "FanSpeed": 0}, find(up, "Ventilateur")
    assert not any("'Ventilateur'" in l for l in out if l.startswith("LOG")), "Done response taken for a refusal"
    assert find(up, "Lumiere ventilateur")["Power"] == 1
    assert find(up, "Porche") == {"Name": "Porche", "Power": 0, "Bri": 254, "CT": 500}, find(up, "Porche")
    assert find(up, "Radio 1")["Power"] == 0 and find(up, "Radio 2")["Power"] == 0
    p1 = find(up, "Pergola 1")
    assert p1["Power"] == 1 and p1["Sat"] == 0 and p1["Bri"] == 126, p1
    pl = find(up, "Prise Lisseur")
    assert pl["Power"] == 0 and abs(pl["Voltage"] - 231.0) < 0.01, pl
    t = find(up, "Temperature SdB")
    assert abs(t["Temperature"] - 21.5) < 0.01, t
    assert abs(find(up, "Humidite SdB")["Humidity"] - 56.0) < 0.01
    for ip in ("10.0.0.18", "10.0.0.80", "10.0.0.15", "10.0.0.31"):
        assert any(e[0] == "session" for e in DEVS[ip].log), ip    # 3.4/3.5 negotiation done
    ok += 1
    # one TCP connection per Wi-Fi device (top-level entry); gateway sub-devices use the gateway's
    conns = [l.split()[1] for l in out if l.startswith("CONNECT ")]
    assert sorted(conns) == sorted(d["ip"] for d in CONFIG["devices"]), conns
    assert resp(h.send("CMD TuyaEnable"), "TuyaEnable")["State"] == "running"
    web = [l for l in h.send("SENSOR") if "Tuya Local" in l]
    assert web and "<a href='/tuya'><button>&#x1F50C; Tuya Local</button></a>" in web[-1], web
    print("OK 1 start, connection + negotiation + initial state (6 devices, 3.3/3.4/3.5, gateway), active button")

    # 2. Matter -> 3.5 fan: 50 % speed then off
    out = h.pump(h.send('MTR {"ep1":{"Ep":1,"Name":"Ventilateur","FanMode":2,"FanSpeed":50,"FanSpeed255":128}}'))
    fan = DEVS["10.0.0.18"]
    assert fan.dps["60"] is True and fan.dps["62"] == 3, fan.dps
    assert find(mtr_updates(out), "Ventilateur")["FanSpeed"] == 50
    out = h.pump(h.send('MTR {"ep1":{"Ep":1,"Name":"ventilateur","FanMode":0,"FanSpeed":0,"FanSpeed255":0}}'))
    assert fan.dps["60"] is False, fan.dps
    ok += 1
    print("OK 2 Matter -> fan (3.5): speed and off, state feedback")

    # 3. Matter -> 3.3 CCT bulb: on, brightness, colour temperature
    porch = DEVS["10.0.0.174"]
    h.pump(h.send('MTR {"ep3":{"Ep":3,"Name":"Porche","Power":1}}'))
    assert porch.dps["20"] is True
    h.pump(h.send('MTR {"ep3":{"Ep":3,"Name":"Porche","Bri":127,"Dimmer":50}}'))
    assert porch.dps["22"] == 10 + (126 * 990 + 126) // 253, porch.dps
    out = h.pump(h.send('MTR {"ep3":{"Ep":3,"Name":"Porche","CT":153}}'))
    assert porch.dps["23"] == 1000, porch.dps
    assert find(mtr_updates(out), "Porche")["CT"] == 153
    ok += 1
    print("OK 3 Matter -> CCT bulb (3.3): on, brightness, temperature")

    # 4. Matter -> 3.4 RGB floodlight: hue/saturation then brightness in colour mode
    perg = DEVS["10.0.0.31"]
    out = h.pump(h.send('MTR {"ep5":{"Ep":5,"Name":"Pergola 1","Hue":85,"Sat":254}}'))
    assert perg.dps["21"] == "colour", perg.dps
    assert perg.dps["24"][:8] == "%04x%04x" % ((85 * 360 + 127) // 254, 1000), perg.dps
    u = find(mtr_updates(out), "Pergola 1")
    assert u["Hue"] == 85 and u["Sat"] == 254, u
    h.pump(h.send('MTR {"ep5":{"Ep":5,"Name":"Pergola 1","Bri":254,"Dimmer":100}}'))
    assert perg.dps["24"][8:] == "03e8" and perg.dps["21"] == "colour", perg.dps
    ok += 1
    print("OK 4 Matter -> RGB floodlight (3.4): colour and brightness")

    # 5. 3.3 gateway: Zigbee plug (cid) driven from Matter, measurements reported
    gw = DEVS["10.0.0.180"]
    out = h.pump(h.send('MTR {"ep7":{"Ep":7,"Name":"Prise Lisseur","Power":1}}'))
    assert gw.children["00158d0000000001"]["1"] is True
    assert find(mtr_updates(out), "Prise Lisseur")["Power"] == 1
    # spontaneous measurement update from the gateway
    push = gw.push({"cid": "00158d0000000001", "dps": {"19": 1234, "18": 5300}, "t": 2})
    out = h.pump(h.send("RX 10.0.0.180 " + push.hex()))
    u = find(mtr_updates(out), "Prise Lisseur")
    assert abs(u["ActivePower"] - 123.4) < 0.01 and abs(u["Current"] - 5.3) < 0.01, u
    ok += 1
    print("OK 5 Zigbee gateway (3.3, cid): command and measurements")

    # 6. Tasmota sensor readings of the clamp meter
    out = h.send("SENSOR")
    app = [l for l in out if l.startswith("APPEND ")][0][len("APPEND "):]
    tele = json.loads("{" + app[1:] + "}")["Tuya"]["Pince"]
    assert abs(tele["Energie"] - 22687.03) < 0.01 and tele["Puissance"] == 592, tele
    assert any("Pince Tension A" in l and "235.0 V" in l for l in out if l.startswith("WEB ")), out
    ok += 1
    print("OK 6 SENSOR readings and web page (3.5 clamp)")

    # 7. TuyaSend and TuyaStatus commands
    out = h.pump(h.send("CMD TuyaSend Recepteur radio,3,true"))
    assert DEVS["10.0.0.15"].dps["3"] is True
    out = h.send("CMD TuyaStatus")
    st = json.loads([l for l in out if l.startswith("RESP ")][0][5:])["TuyaStatus"]
    assert st["Recepteur radio"]["Connected"] and st["Recepteur radio"]["Dps"]["3"] is True, st
    assert st["Prise Lisseur"]["Dps"]["19"] == 1234
    ok += 1
    print("OK 7 TuyaSend / TuyaStatus")

    # 8. heartbeat every 10 s, disconnection, reconnection with a new negotiation
    hb0 = fan.hb
    out = h.pump(h.send("ADV 10500"))
    assert fan.hb > hb0, (fan.hb, hb0)
    out = h.send("DROP 10.0.0.18")
    out += h.send("ADV 100")
    assert any(l.startswith("CLOSE 10.0.0.18") for l in out), out
    out = h.pump(h.send("ADV 6000"))
    assert any(l.startswith("CONNECT 10.0.0.18") for l in out), out
    sessions = [e for e in fan.log if e[0] == "session"]
    assert len(sessions) >= 2, sessions
    h.pump(h.send('MTR {"ep1":{"Ep":1,"Name":"Ventilateur","FanMode":3,"FanSpeed":100,"FanSpeed255":255}}'))
    assert fan.dps["60"] is True and fan.dps["62"] == 6, fan.dps
    ok += 1
    print("OK 8 heartbeat, disconnection and reconnection (new session key)")

    # 9. silent device: disconnection after 35 s without a reply
    radio_ip = "10.0.0.15"
    saved = DEVS[radio_ip].feed
    DEVS[radio_ip].feed = lambda d: []
    out = []
    for _ in range(8):
        out += h.pump(h.send("ADV 5000"))
    assert any("Recepteur radio" in l and "no more replies" in l for l in out), [l for l in out if "LOG" in l][-5:]
    DEVS[radio_ip].feed = saved
    ok += 1
    print("OK 9 detection of a silent device")

    # 10. corrupted frame: rejected without crashing
    bad = bytearray(gw.push({"cid": "00158d0000000002", "dps": {"1": 300}}))
    bad[-10] ^= 0xFF
    out = h.send("RX 10.0.0.180 " + bytes(bad).hex())
    assert any("invalid CRC" in l for l in out), out
    good = gw.push({"cid": "00158d0000000002", "dps": {"1": 199}})
    out = h.pump(h.send("RX 10.0.0.180 " + good.hex()))
    assert abs(find(mtr_updates(out), "Temperature SdB")["Temperature"] - 19.9) < 0.01
    ok += 1
    print("OK 10 corrupted frame rejected, the next one is processed")

    # 11. frame received in two pieces, then two frames in the same packet (3.5)
    f1 = DEVS["10.0.0.18"].push({"protocol": 4, "t": 3, "data": {"dps": {"20": False}}})
    f2 = DEVS["10.0.0.18"].push({"protocol": 4, "t": 4, "data": {"dps": {"62": 4}}})
    out = h.send("RX 10.0.0.18 " + f1[:23].hex())
    assert not mtr_updates(out), out
    out = h.send("RX 10.0.0.18 " + f1[23:].hex())
    assert find(mtr_updates(out), "Lumiere ventilateur")["Power"] == 0, out
    out = h.send("RX 10.0.0.18 " + (f2 + f1).hex())
    assert find(mtr_updates(out), "Ventilateur")["FanSpeed"] == 67, mtr_updates(out)
    ok += 1
    print("OK 11 fragmented frame and grouped frames")

    # 12. missing Matter endpoint: the MtrUpdate refusal is logged
    h.close()
    cfg = json.loads(json.dumps(CONFIG))
    cfg["devices"][3]["matter"][0]["ep"] = "Inconnu"
    with open("/tuya.json", "w") as f:
        json.dump(cfg, f)
    h = Harness()
    h.send("ZIGBEE 1")
    h.send("CMD TuyaEnable 1")
    out = h.pump(h.send("SECOND"))                     # new driver instance: enabled, Zigbee ready
    out += h.pump(h.send("ADV 50"))
    assert any("Matter endpoint 'Inconnu': Invalid Device" in l for l in out), [l for l in out if "LOG" in l]
    ok += 1
    print("OK 12 missing Matter endpoint reported")

    # 13. Matter endpoint created after the driver started: full state resent every 30 s while
    # it is refused, reported only once, then nothing more once accepted
    def adv(ms):
        out = []
        for _ in range(ms // 10000):
            out += h.pump(h.send("ADV 10000"))
        return out
    out = adv(30000)
    assert find(mtr_updates(out), "Inconnu") == {"Name": "Inconnu", "Power": 0}, mtr_updates(out)
    assert not any("'Inconnu'" in l for l in out if l.startswith("LOG")), "refusal reported twice"
    assert find(mtr_updates(out), "Ventilateur") == {}, "Done: the endpoint must not be resent"
    h.send("EPADD Inconnu")                       # the endpoint is created in Configuration -> Matter
    out = adv(30000)
    assert find(mtr_updates(out), "Inconnu") == {"Name": "Inconnu", "Power": 0}, mtr_updates(out)
    assert any("Matter endpoint 'Inconnu' available" in l for l in out), [l for l in out if "LOG" in l]
    out = adv(30000)
    assert find(mtr_updates(out), "Inconnu") == {}, "endpoint accepted: no more resend"
    push = DEVS["10.0.0.15"].push({"protocol": 4, "t": 5, "data": {"dps": {"1": True}}})
    out = h.pump(h.send("RX 10.0.0.15 " + push.hex()))
    assert find(mtr_updates(out), "Inconnu") == {"Name": "Inconnu", "Power": 1}, mtr_updates(out)
    ok += 1
    print("OK 13 Matter endpoint created later: state sent without a restart")

    # 14. API: configuration without the keys, add, key kept, TuyaSend by code, delete
    out = h.send("CMD TuyaConfig")
    conf = resp(out, "TuyaConfig")
    assert len(conf["devices"]) == 6 and all(d["key"] == "***" for d in conf["devices"]), conf
    assert resp(h.send("CMD TuyaConfig Pince"), "TuyaConfig")["name"] == "Pince"
    st = json.loads([l for l in h.send("CMD TuyaStatus pince") if l.startswith("RESP ")][0][5:])["TuyaStatus"]
    assert list(st) == ["Pince"], st
    K["plug"] = "pLuG-kEy-0123456"
    DEVS["10.0.0.99"] = FakeDevice("plugtest0000000000000", K["plug"], 3.3, {"1": False})
    plug = {"name": "Prise test", "id": "plugtest0000000000000", "key": K["plug"], "ip": "10.0.0.99", "version": "3.3"}
    out = h.pump(h.send("CMD TuyaAdd " + json.dumps(plug)))
    assert resp(out, "TuyaAdd") == "Prise test", out
    plug.update({"key": "***", "codes": {"switch": 1}, "matter": [{"ep": "Prise test", "type": "relay", "dp": 1}]})
    out = h.pump(h.send("CMD TuyaAdd " + json.dumps(plug)))
    saved = [d for d in json.load(open("/tuya.json"))["devices"] if d["id"] == plug["id"]][0]
    assert saved["key"] == K["plug"] and saved["codes"] == {"switch": 1}, saved
    out = h.pump(h.send("CMD TuyaSend Prise test,switch,true"))
    assert DEVS["10.0.0.99"].dps["1"] is True, DEVS["10.0.0.99"].dps
    assert "Unknown DP" in h.send("CMD TuyaSend Prise test,inexistant,1")[-1]
    assert "Error" in resp(h.send("CMD TuyaAdd {not json"), "TuyaAdd")
    out = h.pump(h.send("CMD TuyaDel Prise test"))
    assert resp(out, "TuyaDel") == "Prise test"
    assert all(d["id"] != plug["id"] for d in json.load(open("/tuya.json"))["devices"])
    assert any(d["id"] == plug["id"] for d in json.load(open("/tuya.json.bak"))["devices"])
    ok += 1
    print("OK 14 API: TuyaConfig without keys, TuyaAdd (key kept), TuyaSend by code, TuyaDel")

    # 15. network discovery: 3.1 / 3.3 / 3.5 announcements, 3.5 request broadcast, end published
    from fake_tuya import udp_broadcast, decrypt_udp
    out = h.send("CMD TuyaScan 5")
    assert "5 s" in resp(out, "TuyaScan"), out
    assert sum(l.startswith("UDPBIND ") for l in out) == 3, out
    req = [l for l in out if l.startswith("UDPTX 255.255.255.255 7000 ")]
    assert req, out
    req_pkt = bytes.fromhex(req[0].split()[3])
    assert json.loads(decrypt_udp(req_pkt)) == {"from": "app", "ip": "10.0.0.2"}
    assert struct_cmd(req_pkt) == 0x25
    LAMP = {"ip": "10.0.0.50", "gwId": "lamp330000000000000aa", "active": 2, "ability": 0, "mode": 0,
            "encrypt": True, "productKey": "keylamp", "version": "3.3"}
    MPLUG = {"ip": "10.0.0.51", "gwId": "mplug35000000000000bb", "uuid": "u1", "active": 2, "ablilty": 0,
             "encrypt": True, "productKey": "keyplug", "version": "3.5", "token": True, "wf_cfg": True}
    OLD = {"ip": "10.0.0.52", "gwId": "old31000000000000000cc", "active": 2, "ability": 0, "mode": 0,
           "encrypt": False, "productKey": "keyold", "version": "3.1"}
    h.send("UDP 6667 10.0.0.50 " + udp_broadcast(3.3, LAMP).hex())
    h.send("UDP 7000 10.0.0.51 " + udp_broadcast(3.5, MPLUG).hex())
    h.send("UDP 6666 10.0.0.52 " + udp_broadcast(3.1, OLD).hex())
    h.send("UDP 7000 10.0.0.2 " + req_pkt.hex())                     # our own request: ignored
    h.send("UDP 6667 10.0.0.53 " + "00" * 40)                          # invalid packet: ignored
    out = h.send("ADV 6000")
    pub = [json.loads(l[4:]) for l in out if l.startswith("PUB ") and "TuyaScan" in l]
    assert pub, out
    found = {d["id"]: d for d in pub[0]["TuyaScan"]["Devices"]}
    assert set(found) == {"lamp330000000000000aa", "mplug35000000000000bb", "old31000000000000000cc"}, found
    assert found["mplug35000000000000bb"]["version"] == "3.5" and found["lamp330000000000000aa"]["ip"] == "10.0.0.50"
    assert sum(l.startswith("UDPCLOSE ") for l in out) == 3
    h.send("HEAP 10")
    assert "memory" in resp(h.send("CMD TuyaScan"), "TuyaScan")["Error"]
    h.send("HEAP 60")
    ok += 1
    print("OK 15 discovery: 3.1/3.3/3.5 announcements (TinyTuya format), 3.5 request, result published")

    # 16. import of tinytuya's devices.json: only the devices found or known, types deduced
    #     from the DP codes, sub-device attached, read in chunks
    K["lamp"] = "LaMp-KeY-0000001"
    K["mplug"] = "MpLuG-KeY-000002"
    DEVS["10.0.0.50"] = FakeDevice("lamp330000000000000aa", K["lamp"], 3.3, {"20": False, "21": "white", "22": 500, "23": 0})
    DEVS["10.0.0.51"] = FakeDevice("mplug35000000000000bb", K["mplug"], 3.5, {"1": False, "18": 0, "19": 0, "20": 2300})
    DEVS["10.0.0.180"].children["00158d00000000ff"] = {"1": False}         # Zigbee sub-device of the gateway
    def mp(*items):
        return {str(dp): {"code": code, "type": typ, "values": vals} for dp, code, typ, vals in items}
    devices_json = [
        {"name": "Lampe test", "id": "lamp330000000000000aa", "key": K["lamp"], "category": "dj", "icon": "x" * 600,
         "mapping": mp((20, "switch_led", "Boolean", {}), (21, "work_mode", "Enum", {"range": ["white", "colour"]}),
                       (22, "bright_value_v2", "Integer", {"min": 10, "max": 1000, "scale": 0, "step": 1}),
                       (23, "temp_value_v2", "Integer", {"min": 0, "max": 1000, "scale": 0, "step": 1}))},
        {"name": "Prise mesure", "id": "mplug35000000000000bb", "key": K["mplug"], "category": "cz", "ip": "10.0.0.51",
         "version": "3.5",
         "mapping": mp((1, "switch", "Boolean", {}), (18, "cur_current", "Integer", {"unit": "mA", "scale": 0}),
                       (19, "cur_power", "Integer", {"unit": "W", "scale": 1}),
                       (20, "cur_voltage", "Integer", {"unit": "V", "scale": 1}))},
        {"name": "Ventilateur", "id": "fan000000000000000000", "key": K["fan"], "category": "fs", "mapping": {}},
        {"name": "Ailleurs", "id": "remote000000000000000", "key": "rEmOtE-kEy-00003", "category": "kg",
         "mapping": mp((1, "switch_1", "Boolean", {}), (2, "switch_2", "Boolean", {}))},
        {"name": "Enorme", "id": "huge00000000000000000", "key": "x", "icon": "y" * 9000},
        {"name": "Prise Z", "id": "zsub00000000000000000", "key": K["gw"], "sub": True, "node_id": "00158d00000000ff",
         "parent": "gw0000000000000000000", "category": "cz", "mapping": mp((1, "switch", "Boolean", {}))},
    ]
    with open("/devices.json", "w") as f:
        json.dump(devices_json, f, indent=1)
    out = h.pump(h.send("CMD TuyaImport"))
    r = resp(out, "TuyaImport")
    assert sorted(r["Added"]) == ["Lampe test", "Prise Z", "Prise mesure"] and r["Updated"] == ["Ventilateur"], r
    devs = {d["id"]: d for d in json.load(open("/tuya.json"))["devices"]}
    lamp = devs["lamp330000000000000aa"]
    assert lamp["ip"] == "10.0.0.50" and lamp["version"] == "3.3", lamp
    assert lamp["matter"] == [{"ep": "Lampe test", "type": "light2", "dp": 20, "dp_bri": 22, "bri_min": 10,
                               "bri_max": 1000, "dp_mode": 21, "dp_ct": 23}], lamp["matter"]
    pm = devs["mplug35000000000000bb"]["matter"][0]
    assert pm["type"] == "relay_power" and pm["div_power"] == 10 and pm["div_voltage"] == 10 and pm["div_current"] == 1000, pm
    assert devs["fan000000000000000000"]["matter"][0]["type"] == "fan"          # existing bindings kept
    gwc = [c for c in devs["gw0000000000000000000"]["children"] if c.get("cid") == "00158d00000000ff"]
    assert gwc and gwc[0]["matter"][0]["type"] == "relay" and "key" not in gwc[0], gwc
    assert "remote000000000000000" not in devs
    up = mtr_updates(out)
    assert find(up, "Lampe test")["Power"] == 0 and abs(find(up, "Prise mesure")["Voltage"] - 230.0) < 0.01, up
    h.pump(h.send("CMD TuyaSend Lampe test,switch_led,true"))
    assert DEVS["10.0.0.50"].dps["20"] is True
    out = h.pump(h.send("CMD TuyaImport /devices.json all"))
    r = resp(out, "TuyaImport")
    assert "Ailleurs" in r["Added"] and "Enorme" not in r["Added"] + r["Updated"], r
    assert any("too big" in l for l in out), [l for l in out if l.startswith("LOG")]
    remote = [d for d in json.load(open("/tuya.json"))["devices"] if d["id"] == "remote000000000000000"][0]
    assert remote["enabled"] is False and [b["ep"] for b in remote["matter"]] == ["Ailleurs 1", "Ailleurs 2"], remote
    ok += 1
    print("OK 16 devices.json import: filter, deduced types, sub-device, chunked reading")

    # 17. import from the Tuya cloud: signature identical to TinyTuya's, key and DPs fetched, memory guard
    cloud_id = "cloudsw0000000000000"
    # real responses: "t" in ms exceeds Berry's 32-bit integers (json.load -> nil without quote_big)
    h.send('HTTPSRESP /v1.0/token?grant_type=1 200 {"success":true,"result":{"access_token":"tok123","expire_time":7200},'
           '"t":1794092132086,"tid":"0123456789abcdef"}')
    h.send('HTTPSRESP /v1.0/devices/%s 200 {"success":true,"result":{"id":"%s","name":"Cloud double",'
           '"local_key":"cLoUd-KeY-000004","category":"kg","update_time":1794051789},"t":1794092132587}' % (cloud_id, cloud_id))
    h.send('HTTPSRESP /v1.1/devices/%s/specifications 200 {"success":true,"result":{"category":"kg","functions":'
           '[{"code":"switch_1","dp_id":1,"type":"Boolean","values":"{}"},{"code":"switch_2","dp_id":2,'
           '"type":"Boolean","values":"{}"}],"status":[]},"t":1794092133494}' % cloud_id)
    creds = {"region": "eu", "id": "AcCeSsId0123", "secret": "s3cr3t-s3cr3t", "devices": [cloud_id]}
    h.send("HEAP 30")
    assert "memory" in resp(h.send("CMD TuyaCloud " + json.dumps(creds)), "TuyaCloud")["Error"]
    h.send("HEAP 60")
    out = h.send("CMD TuyaCloud " + json.dumps(creds))
    assert "1 device" in resp(out, "TuyaCloud")
    for _ in range(5):
        out += h.pump(h.send("ADV 1000"))
    reqs = [l for l in out if l.startswith("HTTPS ")]
    assert len(reqs) == 3, reqs
    for l in reqs:
        _, url, hdr = l.split(" ", 2)
        hdr = json.loads(hdr)
        assert hdr["sign"] == tinytuya_sign(creds, url, hdr), (url, hdr)
    assert json.loads(reqs[0].split(" ", 2)[2])["secret"] == creds["secret"]       # like tinytuya
    assert json.loads(reqs[1].split(" ", 2)[2])["access_token"] == "tok123"
    pub = [json.loads(l[4:])["TuyaCloud"] for l in out if l.startswith("PUB ") and "TuyaCloud" in l]
    assert pub and pub[-1]["Added"] == ["Cloud double"], pub
    cd = [d for d in json.load(open("/tuya.json"))["devices"] if d["id"] == cloud_id][0]
    assert cd["key"] == "cLoUd-KeY-000004" and cd["enabled"] is False and len(cd["matter"]) == 2, cd
    h.send('HTTPSRESP /v1.0/token?grant_type=1 200 {"success":false,"code":1004,"msg":"sign invalid","t":1794092134511}')
    out = h.send("CMD TuyaCloud " + json.dumps(creds))
    out += h.pump(h.send("ADV 1000"))
    err = [json.loads(l[4:])["TuyaCloud"] for l in out if l.startswith("PUB ") and "TuyaCloud" in l]
    assert err and "sign invalid" in err[-1]["Error"], out
    ok += 1
    print("OK 17 cloud import: TinyTuya signature, 64-bit timestamp, key and DPs, errors and memory guard")

    # 18. web page: list, editing (key masked then kept), deletion, Matter endpoints
    btn, _ = page_btn(h)
    assert "action='tuya'" in btn
    html, _ = page("GET", {})
    assert "Lampe test" in html and "Prise mesure" in html and "Discover devices" in html, html[:300]
    assert K["clamp"] not in html and K["lamp"] not in html
    # Matter list: a checkbox per binding; existing endpoint with its number, missing ones flagged
    assert "<td>Porche</td><td style='font-size:smaller;'>v_light2</td><td style='font-size:smaller;'>" \
           "<span title='endpoint 1'>&#x2705;1</span></td>" in html, html
    assert "<td>Lampe test</td><td style='font-size:smaller;'>v_light2</td><td style='font-size:smaller;'>" \
           "<span title='missing'>&#x26A0;</span></td>" in html, html
    boxes = dict((v, n) for n, v in re.findall(r"<input type='checkbox' name='(m\d+)' value='([^']*)'>", html))
    assert "Lampe test" in boxes and "Ventilateur" in boxes and "Porche" in boxes, boxes
    mn = re.findall(r"name='mn' value='(\d+)'", html)[0]
    assert int(mn) == len(boxes) and "title='all'" in html and " missing. Tick bindings, then:" in html, html
    html, _ = page("GET", {"edit": "Pince"})
    assert "&quot;key&quot;: &quot;***&quot;" in html and K["clamp"] not in html, html
    pince = [d for d in json.load(open("/tuya.json"))["devices"] if d["name"] == "Pince"][0]
    pince["key"] = "***"
    pince["sensors"]["Puissance B"] = [134, 1, "W"]
    html, _ = page("POST", {"save": "", "ref": "Pince", "json": json.dumps(pince)})
    assert html.endswith("REDIRECT /tuya"), html
    pince = [d for d in json.load(open("/tuya.json"))["devices"] if d["name"] == "Pince"][0]
    assert pince["key"] == K["clamp"] and "Puissance B" in pince["sensors"], pince
    html, _ = page("GET", {})
    assert "Saved: Pince" in html
    page("POST", {"del": "", "ref": "Cloud double"})
    assert all(d["name"] != "Cloud double" for d in json.load(open("/tuya.json"))["devices"])
    html, out = page("POST", {"matter": "", "mn": mn})             # nothing ticked
    assert not any(l.startswith("MATTERADD ") for l in out) and html.endswith("REDIRECT /tuya"), html
    html, _ = page("GET", {})
    assert "Error: no endpoint selected" in html
    html, out = page("POST", {"matter": "", "mn": mn, boxes["Porche"]: "Porche", boxes["Lampe test"]: "Lampe test",
                              boxes["Ventilateur"]: "Ventilateur"})    # Porche exists: ignored
    added = [json.loads(l[10:]) for l in out if l.startswith("MATTERADD ")]
    assert {a["name"]: a["type"] for a in added} == {"Lampe test": "v_light2", "Ventilateur": "v_fan"}, added
    assert html.endswith("REDIRECT /?rst="), html
    html, _ = page("GET", {})
    assert "<td>Lampe test</td><td style='font-size:smaller;'>v_light2</td><td style='font-size:smaller;'>" \
           "<span title='endpoint 3'>&#x2705;3</span></td>" in html, html
    out = h.send("CMD TuyaMatter prise MESURE, inexistant")           # by name, case-insensitive
    assert resp(out, "TuyaMatter")["Added"] == ["Prise mesure"], out
    out = h.send("CMD TuyaMatter")                                     # all the remaining ones
    assert "Prise mesure" not in resp(out, "TuyaMatter")["Added"] and resp(out, "TuyaMatter")["Restart"], out
    html, _ = page("GET", {})
    assert "Every active binding has its Matter endpoint" in html and "name='matter'" not in html, html
    html, _ = page("POST", {"scan": ""})
    html, _ = page("GET", {})
    assert "Discovery in progress" in html
    ok += 1
    print("OK 18 web page: list, editing (masked key), deletion, Matter endpoints, discovery")

    # 19. TuyaSend toggle (Zigbee button -> Tuya light): inverts the known state of a boolean DP
    lampdev = DEVS["10.0.0.50"]
    before = lampdev.dps["20"]
    h.pump(h.send("CMD TuyaSend Lampe test,20,toggle"))
    assert lampdev.dps["20"] is (not before), lampdev.dps
    h.pump(h.send("CMD TuyaSend Lampe test,switch_led,TOGGLE"))
    assert lampdev.dps["20"] is before, lampdev.dps
    assert "not boolean" in h.send("CMD TuyaSend Lampe test,22,toggle")[-1]
    assert "unknown" in h.send("CMD TuyaSend Lampe test,99,toggle")[-1]
    ok += 1
    print("OK 19 TuyaSend toggle: boolean DP inverted, refused otherwise")

    # 20. saved cloud credentials (page checkbox): outside tuya.json, secret never shown
    with open("/tuya_cloud.json", "w") as f:
        f.write("")
    html, _ = page("GET", {})
    assert "name='keep'>" in html and "value=''" in html, html
    saved = {"region": "eu", "id": "SaVeDiD0123", "secret": "s4v3d-s3cr3t"}
    h.pump(h.send("ADV 30000"))                                    # end of the discovery of scenario 18
    html, _ = page("POST", {"cloud": "", "region": "eu", "cid": saved["id"], "secret": saved["secret"], "keep": "on"})
    assert json.load(open("/tuya_cloud.json")) == saved
    assert saved["secret"] not in open("/tuya.json").read()
    html, _ = page("GET", {})
    assert "no device" in html and "(credentials saved)" in html, html[:400]   # no discovery
    for _ in range(8):
        h.pump(h.send("ADV 1000"))
    html, _ = page("GET", {})
    assert "name='keep' checked>" in html and "value='%s'" % saved["id"] in html, html
    assert saved["secret"] not in html and "Access Secret (saved, leave empty)" in html
    assert saved["secret"] not in json.dumps(resp(h.send("CMD TuyaConfig"), "TuyaConfig"))
    h.send('HTTPSRESP /v1.0/token?grant_type=1 200 {"success":true,"result":{"access_token":"tok123"},"t":1794092132086}')
    out = h.send("CMD TuyaCloud " + json.dumps({"devices": [cloud_id]}))   # saved credentials
    assert resp(out, "TuyaCloud") == "cloud import started for 1 device(s)", out
    for _ in range(5):
        out += h.pump(h.send("ADV 1000"))
    reqs = [l for l in out if l.startswith("HTTPS ")]
    assert reqs, out
    hdr = json.loads(reqs[0].split(" ", 2)[2])
    assert hdr["client_id"] == saved["id"] and hdr["sign"] == tinytuya_sign(saved, reqs[0].split(" ")[1], hdr), hdr
    html, _ = page("POST", {"cloud": "", "region": "eu", "cid": saved["id"], "secret": ""})   # box unchecked
    assert open("/tuya_cloud.json").read() == ""
    html, _ = page("GET", {})
    assert "name='keep'>" in html and saved["id"] not in html, html
    for _ in range(8):
        h.pump(h.send("ADV 1000"))
    assert "Access ID and Access Secret required" in resp(h.send("CMD TuyaCloud"), "TuyaCloud")["Error"]
    ok += 1
    print("OK 20 saved cloud credentials: page checkbox, TuyaCloud without argument, erasing")

    # 21. firmware without Matter (or Matter disabled): no MtrUpdate, nothing pending, page and
    #     TuyaMatter say so; everything comes back with Matter
    h.send("NOMATTER")
    out = h.pump(h.send("CMD TuyaSend Lampe test,20,toggle"))
    out += h.pump(h.send("ADV 31000"))                                 # past SYNC_RETRY
    assert not [l for l in out if l.startswith("CMD MtrUpdate")], out
    assert not any("retry every 30 s" in l for l in out), [l for l in out if l.startswith("LOG")]
    html, _ = page("GET", {})
    assert "Matter is not enabled" in html and "name='m0'" not in html, html
    assert resp(h.send("CMD TuyaMatter"), "TuyaMatter")["Error"] == "Matter is not enabled"
    h.send("MATTERON")
    h.send("MATTEROFF")                                 # Matter built in but disabled: same
    out = h.pump(h.send("CMD TuyaSend Lampe test,20,toggle"))
    out += h.pump(h.send("ADV 31000"))
    assert not [l for l in out if l.startswith("CMD MtrUpdate")], out
    assert "Matter is not enabled" in page("GET", {})[0]
    h.send("MATTERON")
    out = h.pump(h.send("CMD TuyaSend Lampe test,20,toggle"))
    assert "Power" in find(mtr_updates(out), "Lampe test"), mtr_updates(out)
    ok += 1
    print("OK 21 firmware without Matter or Matter disabled: no MtrUpdate, page and TuyaMatter report it")

    # 22. large tuya.json (as after a cloud import): the page, the editor and the reload read it
    #     entry by entry (512-byte chunks), never in one go; garbage given back after the page
    big = json.load(open("/tuya.json"))
    for i in range(60):
        big["devices"].append({"name": "Gros %02d" % i, "id": "big%017d" % i, "key": "k" * 16,
                               "ip": "10.0.1.%d" % i, "version": "3.3", "enabled": False,
                               "codes": {"switch_%d" % j: j for j in range(1, 30)},
                               "matter": [{"ep": "Gros %02d" % i, "type": "relay", "dp": 1}]})
    with open("/tuya.json", "w") as f:
        json.dump(big, f, indent=1)
    assert os.path.getsize("/tuya.json") > 30000
    html, out = page("GET", {})
    assert all("Gros %02d" % i in html for i in range(60)) and "Lampe test" in html, html[:300]
    assert "GC" in out, out
    html, _ = page("GET", {"edit": "gros 59"})
    assert "big00000000000000059" in html and "&quot;key&quot;: &quot;***&quot;" in html, html[:300]
    out = h.pump(h.send("CMD TuyaReload"))
    assert any("device(s)" in l for l in out if l.startswith("LOG")), out
    ok += 1
    print("OK 22 large tuya.json read entry by entry: page, editor, reload")

    # 23. RAM: a node only keeps the DPs used (bindings, sensors, booleans, "keep"); the others
    #     are still published in the Tuya event
    fan = DEVS["10.0.0.18"]
    out = h.pump(h.send("RX 10.0.0.18 " + fan.push({"protocol": 4, "t": 6, "data": {"dps": {"23": 500, "63": "reverse"}}}).hex()))
    pub = [json.loads(l[4:]) for l in out if l.startswith("PUB ") and '"Tuya"' in l]
    assert pub and pub[-1]["Tuya"]["Dps"] == {"23": 500, "63": "reverse"}, pub
    st = resp(h.send("CMD TuyaStatus Ventilateur"), "TuyaStatus")["Ventilateur"]["Dps"]
    assert set(st) == {"20", "60", "62"}, st                     # 20 bool + light0, 60/62 fan
    fancfg = [d for d in json.load(open("/tuya.json"))["devices"] if d["name"] == "Ventilateur"][0]
    fancfg["key"] = "***"
    fancfg["keep"] = [63]
    out = h.pump(h.send("CMD TuyaAdd " + json.dumps(fancfg)))
    assert resp(out, "TuyaAdd") == "Ventilateur", out
    out = h.pump(h.send("ADV 500"))
    h.pump(h.send("RX 10.0.0.18 " + fan.push({"protocol": 4, "t": 7, "data": {"dps": {"63": "forward", "23": 100}}}).hex()))
    st = resp(h.send("CMD TuyaStatus Ventilateur"), "TuyaStatus")["Ventilateur"]["Dps"]
    assert st.get("63") == "forward" and "23" not in st, st
    # codes are not kept in RAM: TuyaSend by code reads them from tuya.json, here for a gateway
    # sub-device (codes in the gateway entry's "children")
    out = h.pump(h.send("CMD TuyaSend Prise Z,switch,true"))
    assert "RESP Done" in out and DEVS["10.0.0.180"].children["00158d00000000ff"]["1"] is True, out
    assert "Unknown DP" in h.send("CMD TuyaSend Prise Z,nonexistent,true")[-1]
    ok += 1
    print("OK 23 RAM: only the DPs used are kept (bindings, sensors, booleans, keep), all published; codes read from tuya.json")

    # 24. disable without deleting ("enabled": false in tuya.json): a Matter binding (no more
    #     MtrUpdate nor retry, paused in the list), a device (page button), a gateway sub-device
    out = h.pump(h.send("CMD TuyaActive Radio 2,0"))
    assert resp(out, "TuyaActive") == {"Disabled": ["Radio 2"]}, out
    radio = [d for d in json.load(open("/tuya.json"))["devices"] if d["name"] == "Recepteur radio"][0]
    assert [m.get("enabled", True) for m in radio["matter"]] == [True, False], radio
    rdev = DEVS["10.0.0.15"]
    out = h.pump(h.send("RX 10.0.0.15 " + rdev.push({"protocol": 4, "t": 8, "data": {"dps": {"1": True, "2": True}}}).hex()))
    out += h.pump(h.send("ADV 31000"))
    up = mtr_updates(out)
    assert find(up, "Inconnu")["Power"] == 1 and find(up, "Radio 2") == {}, up    # DP 1: renamed "Inconnu" in 12
    html, _ = page("GET", {})
    assert "<td>Radio 2</td><td style='font-size:smaller;'>v_relay</td><td style='font-size:smaller;'>" \
           "<span title='disabled'>&#x23F8;&#xFE0F;</span></td>" in html and "1 disabled" in html, html
    boxes = dict((v, n) for n, v in re.findall(r"<input type='checkbox' name='(m\d+)' value='([^']*)'>", html))
    mn = re.findall(r"name='mn' value='(\d+)'", html)[0]
    html, out = page("POST", {"m_on": "", "mn": mn, boxes["Radio 2"]: "Radio 2"})   # page() pumps
    radio = [d for d in json.load(open("/tuya.json"))["devices"] if d["name"] == "Recepteur radio"][0]
    assert all("enabled" not in m for m in radio["matter"]), radio
    assert "Enabled: Radio 2" in page("GET", {})[0]
    # a device from its edit page; "Pergola 1" is also an endpoint name: only the device changes
    html, _ = page("GET", {"edit": "Pergola 1"})
    assert "name='active' value='0'" in html and "Disable (kept in tuya.json)" in html, html
    html, out = page("POST", {"ref": "perg00000000000000000", "active": "0"})
    perg = [d for d in json.load(open("/tuya.json"))["devices"] if d["name"] == "Pergola 1"][0]
    assert perg["enabled"] is False and "enabled" not in perg["matter"][0], perg
    st = resp(h.send("CMD TuyaStatus"), "TuyaStatus")
    assert "Pergola 1" not in st and "Ventilateur" in st, list(st)
    assert "name='active' value='1'" in page("GET", {"edit": "Pergola 1"})[0]
    # a gateway sub-device by command, then everything back on
    out = h.pump(h.send("CMD TuyaActive Prise Lisseur,0"))
    assert resp(out, "TuyaActive") == {"Disabled": ["Prise Lisseur"]}, out
    assert "Prise Lisseur" not in resp(h.send("CMD TuyaStatus"), "TuyaStatus")
    out = h.pump(h.send("CMD TuyaActive Prise Lisseur,Pergola 1,1"))
    assert sorted(resp(out, "TuyaActive")["Enabled"]) == ["Pergola 1", "Prise Lisseur"], out
    out += h.pump(h.send("ADV 500"))
    st = resp(h.send("CMD TuyaStatus"), "TuyaStatus")
    assert "Prise Lisseur" in st and "Pergola 1" in st, list(st)
    assert "unknown device or endpoint" in resp(h.send("CMD TuyaActive Nothing,0"), "TuyaActive")["Error"]
    assert "syntax" in resp(h.send("CMD TuyaActive Radio 2"), "TuyaActive")["Error"]
    ok += 1
    print("OK 24 disable without deleting: Matter binding, device (page), sub-device (command), enable back")

    # disabling stops the driver: connections closed, no main page button
    out = h.send("CMD TuyaEnable 0")
    assert resp(out, "TuyaEnable") == {"Enabled": False, "State": "disabled"}, out
    assert [l for l in out if l.startswith("CLOSE")], out
    assert not [l for l in h.send("SENSOR") if "Tuya Local" in l]

    h.close()
    print("%d/25 scenarios OK" % ok)


if __name__ == "__main__":
    main()

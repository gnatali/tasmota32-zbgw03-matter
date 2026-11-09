#- tuya_local.be: local control of Tuya Wi-Fi devices from Tasmota (LocalTuya equivalent)

  - Tuya local protocols 3.3, 3.4 and 3.5 (TCP 6668), without the cloud
  - Zigbee sub-devices of a Tuya gateway ("cid" field)
  - Bridge to Matter: virtual endpoints (v_relay, v_light2, v_fan...) driven by the
    MtrReceived event and updated with the MtrUpdate command
  - Measurements (clamp meter...) in Tasmota's sensor telemetry and web page

  Configuration: /tuya.json file (see tuya.example.json and docs/tuya-local.en.md), or the
  Configuration -> Tuya Local web page (/tuya)
  Commands: TuyaStatus [device], TuyaSend <device>,<dp or code>,<value|toggle>, TuyaReload,
    TuyaConfig [device], TuyaAdd <json>, TuyaDel <device>, TuyaScan [s],
    TuyaImport [file] [all|id,...], TuyaCloud [json], TuyaMatter [name,...], TuyaEnable [0|1],
    TuyaActive <device or endpoint>[,...],<0|1>

  Requires a firmware with USE_BERRY_CRYPTO_AES_CBC (3.3, 3.4) and the 128-bit AES_GCM with
  AAD patch (3.5).

  Solidified into the firmware (custom_berry_solidify): the classes are then in flash,
  read-only, and become native classes. Hence three rules:
  - no top-level code outside the classes: the driver is instantiated by autoexec.be
    (`global.tuya_local = TuyaLocal()`), not by this file;
  - modules (string, json, crypto) are imported in the methods that use them;
  - no write to a static variable (`static var`): constants only.
  The file can still be loaded as is with load("tuya_local.be") on a firmware that does not
  embed it (same instantiation afterwards).
-#

#################################################################################
# TuyaCodec: protocol primitives (stateless)
#################################################################################
#@ solidify:TuyaCodec,weak
class TuyaCodec
  # CRC-32 (polynomial 0xEDB88320) by nibble: constant 16-entry table, nothing computed
  # on first call (a solidified class is read-only)
  static var CRC_NIBBLE = [0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC, 0x76DC4190, 0x6B6B51F4,
                           0x4DB26158, 0x5005713C, 0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C,
                           0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C]
  # commands sent without the "3.x" version header + 12 null bytes
  static var NO_HEADER = [3, 4, 5, 9, 10, 16, 18, 64]
  # UDP announcement key (discovery): md5("yGAdlopoPVldABfn"), as in tinytuya
  static var UDP_KEY = bytes("6c1ec8e2bb9bb59ab50b0daf649b410a")

  static def crc32(b, len)
    var t = TuyaCodec.CRC_NIBBLE
    var crc = 0xFFFFFFFF
    var i = 0
    while i < len
      crc = crc ^ b[i]
      crc = t[crc & 0x0F] ^ ((crc >> 4) & 0x0FFFFFFF)
      crc = t[crc & 0x0F] ^ ((crc >> 4) & 0x0FFFFFFF)
      i += 1
    end
    return crc ^ 0xFFFFFFFF
  end

  static def hmac(key, data)
    import crypto
    return crypto.HMAC_SHA256(key).update(data).out()
  end

  static def pad(b)
    var n = 16 - (b.size() % 16)
    var r = b.copy()
    var i = 0
    while i < n  r.add(n, 1)  i += 1  end
    return r
  end

  static def unpad(b)
    var sz = b.size()
    if sz == 0  return b  end
    var n = b[sz - 1]
    if n < 1 || n > 16 || n > sz  return b  end
    return b[0 .. sz - n - 1]
  end

  # AES-128-ECB, block by block, with AES-CBC and a null IV
  static def ecb(key, data, enc)
    import crypto
    var out = bytes()
    var i = 0
    while i < data.size()
      var blk = data[i .. i + 15]
      if enc
        crypto.AES_CBC.encrypt1(key, bytes(-16), blk)
      else
        crypto.AES_CBC.decrypt1(key, bytes(-16), blk)
      end
      out .. blk
      i += 16
    end
    return out
  end

  # 6699 frame (3.5): AES-128-GCM, header (bytes 4 to 17) as authenticated data
  static def frame_6699(seq, cmd, plain, k)
    import crypto
    var b = bytes()
    b.add(0x00006699, -4)
    b.add(0, -2)
    b.add(seq, -4)
    b.add(cmd, -4)
    b.add(12 + size(plain) + 16, -4)
    var iv = crypto.random(12)
    var g = crypto.AES_GCM(k, iv, b[4 .. 17])
    var ct = g.encrypt(plain)
    b .. iv
    b .. ct
    b .. g.tag()
    b.add(0x00009966, -4)
    return b
  end

  # UDP announcement of a device (ports 6666, 6667, 7000) -> JSON map, or nil
  # 55AA: clear text (3.1) or AES-ECB with UDP_KEY (3.3); 6699: AES-GCM with UDP_KEY (3.5)
  static def decode_udp(pkt)
    import crypto
    import json
    var n = size(pkt)
    if n < 28  return nil  end
    var k = TuyaCodec.UDP_KEY
    var pfx = pkt.get(0, -4)
    var p
    if pfx == 0x000055AA
      var total = 16 + pkt.get(12, -4)
      if total > n || total < 28  return nil  end
      p = pkt[20 .. total - 9]                        # after the return code, before CRC + suffix
      if size(p) > 0 && p[0] != 0x7B                  # no '{': encrypted
        if size(p) % 16 != 0  return nil  end
        p = TuyaCodec.unpad(TuyaCodec.ecb(k, p, false))
      end
    elif pfx == 0x00006699
      var total = 18 + pkt.get(14, -4) + 4
      if total > n || total < 50  return nil  end
      var g = crypto.AES_GCM(k, pkt[18 .. 29], pkt[4 .. 17])
      p = g.decrypt(pkt[30 .. total - 21])
      if g.tag() != pkt[total - 20 .. total - 5]  return nil  end
      if size(p) > 4 && p[0] != 0x7B && p[4] == 0x7B  p = p[4 ..]  end   # return code
    else
      return nil
    end
    var sz = size(p)
    while sz > 0 && p[sz - 1] == 0  sz -= 1  end     # trailing null bytes (app)
    if sz == 0  return nil  end
    var m = json.load(p[0 .. sz - 1].asstring())
    return (type(m) == 'instance' && classname(m) == 'map') ? m : nil
  end

  static def version_header(ver)
    var h = bytes().fromstring(ver)
    h .. bytes(-12)
    return h
  end
end

#################################################################################
# TuyaBinding: link between Tuya DPs and a virtual Matter endpoint
#################################################################################
#@ solidify:TuyaBinding,weak
class TuyaBinding
  var node            # TuyaNode (device or sub-device) that holds the DPs
  var ep              # Matter endpoint name
  var type            # relay, relay_power, light0..3, fan, temp, humidity
  var c               # configuration (map)
  var pending         # true: the last MtrUpdate was refused (endpoint missing), to be resent

  def init(node, conf)
    self.node = node
    self.c = conf
    self.ep = conf.find("ep", node.name)
    self.type = conf.find("type", "relay")
  end

  def dp(k, dflt)
    var v = self.c.find(k, dflt)
    return v != nil ? str(v) : nil
  end
  def num(k, dflt)
    return self.c.find(k, dflt)
  end

  # DPs read by to_matter() (defaults included): the node keeps their values
  def dps_used()
    var t = self.type
    if t == "fan"  return [self.dp("dp", 60), self.dp("dp_speed", 62)]  end
    if t == "temp" || t == "humidity"  return [self.dp("dp", t == "temp" ? 1 : 2)]  end
    var light = (t == "light0" || t == "light1" || t == "light2" || t == "light3")
    var l = [self.dp("dp", light ? 20 : 1)]
    if t == "relay_power"
      for k: ["dp_power", "dp_voltage", "dp_current"]
        if self.dp(k) != nil  l.push(self.dp(k))  end
      end
    end
    if t == "light1" || t == "light2" || t == "light3"
      l.push(self.dp("dp_mode", 21))
      l.push(self.dp("dp_bri", 22))
      if t == "light2"  l.push(self.dp("dp_ct", 23))  end
      if t == "light3"  l.push(self.dp("dp_colour", 24))  end
    end
    return l
  end

  # Matter -> Tuya: MtrReceived attributes -> map of DPs to send
  def to_tuya(a)
    import string
    var t = self.type
    var out = {}
    var st = self.node.dps
    if t == "fan"
      var dp_on = self.dp("dp", 60)
      var dp_speed = self.dp("dp_speed", 62)
      var smin = self.num("speed_min", 1)
      var smax = self.num("speed_max", 6)
      var pct = a.find("FanSpeed")
      if pct == nil && a.find("FanMode") != nil
        pct = [0, 33, 67, 100][int(a["FanMode"]) & 3]
      end
      if pct != nil
        pct = int(pct)
        if pct <= 0
          out[dp_on] = false
        else
          var s = (pct * smax + 99) / 100
          if s < smin  s = smin  end
          if s > smax  s = smax  end
          out[dp_on] = true
          out[dp_speed] = s
        end
      end
      return out
    end
    if a.contains("Power")
      out[self.dp("dp", t == "light0" || t == "light1" || t == "light2" || t == "light3" ? 20 : 1)] = bool(a["Power"])
    end
    if t == "light1" || t == "light2" || t == "light3"
      var bmin = self.num("bri_min", 10)
      var bmax = self.num("bri_max", 1000)
      var dp_mode = self.dp("dp_mode", 21)
      var dp_bri = self.dp("dp_bri", 22)
      var dp_col = self.dp("dp_colour", 24)
      var colour = (t == "light3") && (st.find(dp_mode) == "colour")
      if t == "light3" && (a.contains("Hue") || a.contains("Sat"))
        var hsv = self.hsv_get()
        if a.contains("Hue")  hsv[0] = (int(a["Hue"]) * 360 + 127) / 254  end
        if a.contains("Sat")  hsv[1] = (int(a["Sat"]) * 1000 + 127) / 254  end
        if a.contains("Bri")  hsv[2] = self.bri_to_raw(a["Bri"], 10, 1000)  end
        out[dp_mode] = "colour"
        out[dp_col] = string.format("%04x%04x%04x", hsv[0], hsv[1], hsv[2])
      elif a.contains("Bri")
        if colour
          var hsv = self.hsv_get()
          hsv[2] = self.bri_to_raw(a["Bri"], 10, 1000)
          out[dp_col] = string.format("%04x%04x%04x", hsv[0], hsv[1], hsv[2])
        else
          out[dp_bri] = self.bri_to_raw(a["Bri"], bmin, bmax)
          if t == "light3" && st.contains(dp_mode)  out[dp_mode] = "white"  end
        end
      end
      if t == "light2" && a.contains("CT")
        var cmin = self.num("ct_min", 153)       # mireds of Tuya value 1000 (cold)
        var cmax = self.num("ct_max", 500)       # mireds of Tuya value 0 (warm)
        var ct = int(a["CT"])
        if ct < cmin  ct = cmin  end
        if ct > cmax  ct = cmax  end
        out[self.dp("dp_ct", 23)] = ((cmax - ct) * 1000 + (cmax - cmin) / 2) / (cmax - cmin)
        if st.contains(dp_mode) && st[dp_mode] != "white"  out[dp_mode] = "white"  end
      end
    end
    return out
  end

  def bri_to_raw(b, lo, hi)
    b = int(b)
    if b < 1  b = 1  end
    if b > 254  b = 254  end
    return lo + ((b - 1) * (hi - lo) + 126) / 253
  end
  def raw_to_bri(v, lo, hi)
    v = int(v)
    if v < lo  v = lo  end
    if v > hi  v = hi  end
    return 1 + ((v - lo) * 253 + (hi - lo) / 2) / (hi - lo)
  end

  # Tuya colour (colour_data_v2): "hhhhssssvvvv", h 0..360, s and v 0..1000
  def hsv_get()
    var s = self.node.dps.find(self.dp("dp_colour", 24))
    if type(s) == 'string' && size(s) == 12
      return [int("0x" + s[0..3]), int("0x" + s[4..7]), int("0x" + s[8..11])]
    end
    return [0, 1000, 1000]
  end

  # Tuya -> Matter: sends the endpoint the attributes touched by `changed` (map of DPs).
  # If the endpoint refuses (missing, created after the driver...), the binding becomes pending
  # and TuyaLocal resends it the full state every SYNC_RETRY ms. Returns false if refused.
  def push(changed)
    import json
    import global
    # Matter not built into the firmware, or disabled (no configuration): nothing to update,
    # nothing pending
    var md = global.contains("matter_device") ? global.matter_device : nil
    if md == nil || md.plugins_config == nil  return true  end
    var r = self.to_matter(changed)
    if r == nil  return true  end
    r["Name"] = self.ep
    var res = tasmota.cmd("MtrUpdate " + json.dump(r), true)
    var v = (type(res) == 'instance') ? res.find("MtrUpdate") : nil
    # accepted: the endpoint's state, or "Done" for an endpoint that publishes none (v_fan)
    if type(v) == 'instance' || v == "Done"
      if self.pending
        tasmota.log(f"TUY: Matter endpoint '{self.ep}' available, state sent", 2)
        self.pending = false
      end
      return true
    end
    if !self.pending                  # "Invalid Device", "Invalid attribute '...'" or nothing: reported once
      var why = (v != nil) ? v : res
      tasmota.log(f"TUY: Matter endpoint '{self.ep}': {why} (retry every 30 s)", 2)
      self.pending = true
    end
    return false
  end

  # Tuya -> Matter: current state -> MtrUpdate attributes (nil if nothing concerns this endpoint)
  def to_matter(changed)
    var t = self.type
    var st = self.node.dps
    var r = {}
    var hit = false
    if t == "fan"
      var dp_on = self.dp("dp", 60)
      var dp_speed = self.dp("dp_speed", 62)
      if changed.contains(dp_on) || changed.contains(dp_speed)
        var smax = self.num("speed_max", 6)
        var on = st.find(dp_on, false)
        var s = int(st.find(dp_speed, 0))
        r["FanSpeed"] = (on && s > 0) ? (s * 100 + smax / 2) / smax : 0
        if on && r["FanSpeed"] == 0  r["FanSpeed"] = 1  end
        hit = true
      end
      return hit ? r : nil
    end
    if t == "temp" || t == "humidity"
      var d = self.dp("dp", t == "temp" ? 1 : 2)
      if changed.contains(d)
        var v = real(st[d]) / self.num("div", 10)
        r[t == "temp" ? "Temperature" : "Humidity"] = v
        hit = true
      end
      return hit ? r : nil
    end
    var dp_on = self.dp("dp", t == "light0" || t == "light1" || t == "light2" || t == "light3" ? 20 : 1)
    if changed.contains(dp_on)
      r["Power"] = st[dp_on] ? 1 : 0
      hit = true
    end
    if t == "relay_power"
      for k: [["dp_power", "ActivePower", "div_power"], ["dp_voltage", "Voltage", "div_voltage"], ["dp_current", "Current", "div_current"]]
        var d = self.dp(k[0])
        if d != nil && changed.contains(d)
          r[k[1]] = real(st[d]) / self.num(k[2], 1)
          hit = true
        end
      end
    end
    if t == "light1" || t == "light2" || t == "light3"
      var dp_mode = self.dp("dp_mode", 21)
      var dp_bri = self.dp("dp_bri", 22)
      var dp_col = self.dp("dp_colour", 24)
      var colour = (t == "light3") && (st.find(dp_mode) == "colour")
      if colour && (changed.contains(dp_col) || changed.contains(dp_mode))
        var hsv = self.hsv_get()
        r["Hue"] = (hsv[0] * 254 + 180) / 360
        r["Sat"] = (hsv[1] * 254 + 500) / 1000
        r["Bri"] = self.raw_to_bri(hsv[2], 10, 1000)
        hit = true
      elif !colour && (changed.contains(dp_bri) || changed.contains(dp_mode)) && st.contains(dp_bri)
        r["Bri"] = self.raw_to_bri(st[dp_bri], self.num("bri_min", 10), self.num("bri_max", 1000))
        if t == "light3"  r["Sat"] = 0  end
        hit = true
      end
      var dp_ct = self.dp("dp_ct", 23)
      if t == "light2" && changed.contains(dp_ct)
        var cmin = self.num("ct_min", 153)
        var cmax = self.num("ct_max", 500)
        r["CT"] = cmax - (int(st[dp_ct]) * (cmax - cmin) + 500) / 1000
        hit = true
      end
    end
    return hit ? r : nil
  end
end

#################################################################################
# TuyaNode: a logical device (Wi-Fi device or gateway sub-device)
#################################################################################
#@ solidify:TuyaNode,weak
class TuyaNode
  var name, id, cid          # cid: sub-device id (nil for a Wi-Fi device)
  var conn                   # TuyaDevice that holds the TCP connection
  var dps                    # last known state {"1": true, ...}
  var bindings               # list of TuyaBinding
  var sensors                # {"label": [dp, divider, unit]}: Tasmota sensor readings
  var seen                   # millis of the last reception
  var keep                   # ",20,60,62," DPs kept in dps besides booleans, or true ("keep": "all")

  def init(conn, conf)
    self.conn = conn
    self.name = conf.find("name", conf.find("id"))
    self.id = conf.find("id")
    self.cid = conf.find("cid")
    self.dps = {}
    self.bindings = []
    self.sensors = conf.find("sensors", {})
    # the "codes" table (import) is not kept in RAM (~0.3 KB per device): TuyaSend by code reads
    # it from tuya.json when needed (TuyaLocal.code_dp)
    for m: conf.find("matter", [])
      if m.find("enabled", true) != false  self.bindings.push(TuyaBinding(self, m))  end   # disabled: kept in tuya.json only
    end
    # RAM: only the DPs used are kept (bindings, sensor readings, "keep", booleans for toggle);
    # devices send many others (timers, scenes, settings), some as long strings. The set is one
    # short string per node: a map of its own would cost more than the DPs it saves
    var k = conf.find("keep")
    if k == "all"
      self.keep = true
    else
      var l = []
      if type(k) == 'instance'
        for d: k  l.push(str(d))  end
      end
      for b: self.bindings
        for d: b.dps_used()  l.push(d)  end
      end
      for n: self.sensors.keys()  l.push(str(self.sensors[n][0]))  end
      self.keep = "," + l.concat(",") + ","
    end
  end

  def kept(ks)
    import string
    return self.keep == true || string.find(self.keep, "," + ks + ",") >= 0
  end

  # new values received from the device
  def update(dps)
    import json
    var changed = {}
    for k: dps.keys()
      var ks = str(k)
      var v = dps[k]
      if self.dps.find(ks) != v || !self.dps.contains(ks)
        changed[ks] = v                 # unused DPs too: published, rules can use them
      end
      if type(v) == 'bool' || self.kept(ks)  self.dps[ks] = v  end
    end
    self.seen = tasmota.millis()
    if size(changed) == 0  return  end
    tasmota.log(f"TUY: {self.name} {json.dump(changed)}", 3)
    tasmota.publish_result(json.dump({"Tuya": {"Name": self.name, "Dps": changed}}), "RESULT")
    for b: self.bindings
      if b.pending
        b.push(self.dps)                # pending endpoint: full state
      else
        b.push(changed)
      end
    end
  end

  def all_dps()
    var m = {}
    for k: self.dps.keys()  m[k] = self.dps[k]  end
    return m
  end
end

#################################################################################
# TuyaDevice: TCP connection to a Wi-Fi device (or a gateway) and protocol
#################################################################################
#@ solidify:TuyaDevice,weak
class TuyaDevice : TuyaNode
  static var PORT = 6668
  static var ST_IDLE = 0
  static var ST_CONNECTING = 1
  static var ST_NEGO = 2
  static var ST_READY = 3

  var ip, ver, key, sess_key
  var tcp, state, rx, tx
  var seq, nonce
  var children                # {"cid": TuyaNode}
  var t_retry, retry_delay, t_hb, t_last_rx, t_state

  def init(conf)
    super(self).init(self, conf)
    self.ip = conf["ip"]
    self.ver = str(conf.find("version", "3.3"))
    self.key = bytes().fromstring(conf["key"])
    self.children = {}
    for c: conf.find("children", [])
      if c.find("enabled", true) == false  continue  end      # disabled sub-device
      var n = TuyaNode(self, c)
      self.children[str(c["cid"])] = n
    end
    self.state = self.ST_IDLE
    self.rx = bytes()
    self.tx = bytes()
    self.seq = 1
    self.t_retry = 0
    self.retry_delay = 5000
  end

  def is_gateway()  return size(self.children) > 0  end
  def v34()  return self.ver == "3.4" || self.ver == "3.5"  end

  ###################### connection ######################
  def close(reason)
    if self.tcp  self.tcp.close()  end
    self.tcp = nil
    if self.state != self.ST_IDLE
      tasmota.log(f"TUY: {self.name} ({self.ip}) disconnected: {reason}", 2)
    end
    self.state = self.ST_IDLE
    self.rx = bytes()
    self.tx = bytes()
    self.sess_key = nil
    self.t_retry = tasmota.millis() + self.retry_delay
    self.retry_delay = self.retry_delay * 2
    if self.retry_delay > 60000  self.retry_delay = 60000  end
  end

  def connect()
    self.tcp = tcpclientasync()
    self.tcp.connect(self.ip, self.PORT)
    self.state = self.ST_CONNECTING
    self.t_state = tasmota.millis()
    self.seq = 1
  end

  def on_connected()
    import crypto
    tasmota.log(f"TUY: {self.name} ({self.ip}) connected, protocol {self.ver}", 2)
    self.t_last_rx = tasmota.millis()
    self.t_hb = tasmota.millis()
    if self.v34()
      self.state = self.ST_NEGO
      self.t_state = tasmota.millis()
      self.sess_key = nil
      self.nonce = crypto.random(16)
      self.send_raw(3, self.nonce)
    else
      self.on_ready()
    end
  end

  def on_ready()
    self.state = self.ST_READY
    self.retry_delay = 5000
    self.query()
  end

  def loop()
    var now = tasmota.millis()
    if self.state == self.ST_IDLE
      if now >= self.t_retry  self.connect()  end
      return
    end
    var c = self.tcp.connected()
    if self.state == self.ST_CONNECTING
      if c == true
        self.on_connected()
      elif c == false || now - self.t_state > 10000
        self.close("connection failed")
        return
      end
      return
    end
    if c != true
      self.close("connection closed")
      return
    end
    # reception
    if self.tcp.available() > 0
      self.rx .. self.tcp.readbytes()
      self.t_last_rx = now
      self.parse()
      if self.tcp == nil  return  end
    end
    # pending transmission
    self.flush()
    if self.state == self.ST_NEGO && now - self.t_state > 5000
      self.close("no reply to key negotiation")
      return
    end
    if self.state == self.ST_READY
      if now - self.t_last_rx > 35000
        self.close("no more replies")
        return
      end
      if now - self.t_hb > 10000
        self.t_hb = now
        self.send(9, '{"gwId":"' + self.id + '","devId":"' + self.id + '"}')
      end
    end
  end

  def flush()
    if size(self.tx) > 0 && self.tcp
      var n = self.tcp.write(self.tx)
      if n > 0
        self.tx = (n >= size(self.tx)) ? bytes() : self.tx[n ..]
      end
    end
  end

  ###################### transmission ######################
  def time_str()  return str(tasmota.rtc()['utc'])  end

  def query()
    if self.is_gateway()
      for n: self.children
        if self.v34()
          self.send(16, '{"cid":"' + n.cid + '"}')
        else
          self.send(10, '{"t":' + self.time_str() + ',"cid":"' + n.cid + '"}')
        end
      end
    elif self.v34()
      self.send(16, '{}')
    else
      self.send(10, '{"gwId":"' + self.id + '","devId":"' + self.id + '","uid":"' + self.id + '","t":"' + self.time_str() + '"}')
    end
  end

  # sends DPs to a device or a sub-device (node)
  def set_dps(node, dps)
    import json
    if self.state != self.ST_READY
      tasmota.log(f"TUY: {node.name} not connected, command ignored", 2)
      return false
    end
    var d = json.dump(dps)
    if node.cid != nil
      if self.v34()
        self.send(13, '{"protocol":5,"t":' + self.time_str() + ',"data":{"cid":"' + node.cid + '","ctype":0,"dps":' + d + '},"cid":"' + node.cid + '"}')
      else
        self.send(7, '{"t":' + self.time_str() + ',"cid":"' + node.cid + '","dps":' + d + '}')
      end
    elif self.v34()
      self.send(13, '{"protocol":5,"t":' + self.time_str() + ',"data":{"dps":' + d + '}}')
    else
      self.send(7, '{"devId":"' + self.id + '","uid":"' + self.id + '","t":"' + self.time_str() + '","dps":' + d + '}')
    end
    return true
  end

  def send(cmd, payload)
    self.send_raw(cmd, bytes().fromstring(payload))
  end

  def send_raw(cmd, p)
    var hdr = (TuyaCodec.NO_HEADER.find(cmd) == nil)
    var k = self.sess_key != nil ? self.sess_key : self.key
    var frame
    if self.ver == "3.5"
      var plain = hdr ? TuyaCodec.version_header(self.ver) + p : p
      frame = self.frame_6699(cmd, plain, k)
    elif self.ver == "3.4"
      var plain = hdr ? TuyaCodec.version_header(self.ver) + p : p
      frame = self.frame_55aa(cmd, TuyaCodec.ecb(k, TuyaCodec.pad(plain), true), k)
    else
      var body = TuyaCodec.ecb(k, TuyaCodec.pad(p), true)
      if hdr  body = TuyaCodec.version_header(self.ver) + body  end
      frame = self.frame_55aa(cmd, body, nil)
    end
    self.seq += 1
    self.tx .. frame
    self.flush()
  end

  def frame_55aa(cmd, body, hmac_key)
    var b = bytes()
    b.add(0x000055AA, -4)
    b.add(self.seq, -4)
    b.add(cmd, -4)
    b.add(size(body) + (hmac_key ? 36 : 8), -4)
    b .. body
    if hmac_key
      b .. TuyaCodec.hmac(hmac_key, b)
    else
      b.add(TuyaCodec.crc32(b, size(b)), -4)
    end
    b.add(0x0000AA55, -4)
    return b
  end

  def frame_6699(cmd, plain, k)
    return TuyaCodec.frame_6699(self.seq, cmd, plain, k)
  end

  ###################### reception ######################
  def parse()
    while true
      var n = size(self.rx)
      if n < 4  return  end
      var pfx = self.rx.get(0, -4)
      if pfx != 0x000055AA && pfx != 0x00006699
        # resynchronisation: look for the next prefix
        var i = 1
        while i <= n - 4
          var p = self.rx.get(i, -4)
          if p == 0x000055AA || p == 0x00006699  break  end
          i += 1
        end
        self.rx = (i <= n - 4) ? self.rx[i ..] : self.rx[n - 3 ..]
        continue
      end
      var total
      if pfx == 0x000055AA
        if n < 16  return  end
        total = 16 + self.rx.get(12, -4)
      else
        if n < 18  return  end
        total = 18 + self.rx.get(14, -4) + 4
      end
      if total < 24 || total > 4096
        self.close("invalid frame")
        return
      end
      if n < total  return  end
      var frame = self.rx[0 .. total - 1]
      self.rx = (n > total) ? self.rx[total ..] : bytes()
      try
        self.handle(frame)
      except .. as e, m
        tasmota.log(f"TUY: {self.name} decoding error: {e} {m}", 2)
      end
      if self.tcp == nil  return  end
    end
  end

  # decodes a complete frame -> (cmd, clear payload without return code)
  def decode(frame)
    import crypto
    var k = self.sess_key != nil ? self.sess_key : self.key
    var total = size(frame)
    if frame.get(0, -4) == 0x00006699
      var cmd = frame.get(10, -4)
      var iv = frame[18 .. 29]
      var ct = frame[30 .. total - 21]
      var tag = frame[total - 20 .. total - 5]
      var g = crypto.AES_GCM(k, iv, frame[4 .. 17])
      var pt = g.decrypt(ct)
      if g.tag() != tag  raise "tag_error", "GCM authentication failed"  end
      return [cmd, size(pt) >= 4 ? pt[4 ..] : bytes()]
    end
    var cmd = frame.get(8, -4)
    var use_hmac = self.v34()
    var end_len = use_hmac ? 36 : 8
    var signed = frame[0 .. total - end_len - 1]
    if use_hmac
      if TuyaCodec.hmac(k, signed) != frame[total - 36 .. total - 5]  raise "hmac_error", "invalid HMAC"  end
    else
      if TuyaCodec.crc32(signed, size(signed)) != frame.get(total - 8, -4)  raise "crc_error", "invalid CRC"  end
    end
    var body = (total - end_len > 20) ? frame[20 .. total - end_len - 1] : bytes()     # after the return code
    if size(body) == 0  return [cmd, body]  end
    if use_hmac
      body = TuyaCodec.unpad(TuyaCodec.ecb(k, body, false))
      return [cmd, body]
    end
    if size(body) >= 15 && body[0..2].asstring() == self.ver
      body = body[15 ..]
    end
    if size(body) == 0 || size(body) % 16 != 0  return [cmd, bytes()]  end
    return [cmd, TuyaCodec.unpad(TuyaCodec.ecb(k, body, false))]
  end

  def handle(frame)
    import json
    var r = self.decode(frame)
    var cmd = r[0]
    var p = r[1]
    if cmd == 4
      self.nego_step2(p)
      return
    end
    if size(p) == 0  return  end
    if self.v34() && size(p) >= 15 && p[0..2].asstring() == self.ver
      p = p[15 ..]
    end
    var s = p.asstring()
    if s[0] != '{'  return  end
    var m = json.load(s)
    if m == nil
      tasmota.log(f"TUY: {self.name} invalid JSON: {s}", 3)
      return
    end
    var data = m.find("data")
    var dps = m.find("dps")
    var cid = m.find("cid")
    if type(data) == 'instance' && classname(data) == 'map'
      if dps == nil  dps = data.find("dps")  end
      if cid == nil  cid = data.find("cid")  end
    end
    if dps == nil  return  end
    var node = self
    if cid != nil
      node = self.children.find(str(cid))
      if node == nil
        tasmota.log(f"TUY: {self.name} unknown sub-device cid={cid}", 3)
        return
      end
    end
    node.update(dps)
  end

  ###################### key negotiation (3.4 / 3.5) ######################
  def nego_step2(p)
    import crypto
    if self.state != self.ST_NEGO || size(p) < 48
      self.close("negotiation: unexpected reply")
      return
    end
    var remote = p[0 .. 15]
    if TuyaCodec.hmac(self.key, self.nonce) != p[16 .. 47]
      self.close("negotiation: wrong local key?")
      return
    end
    self.send_raw(5, TuyaCodec.hmac(self.key, remote))
    var x = bytes(-16)
    var i = 0
    while i < 16
      x[i] = self.nonce[i] ^ remote[i]
      i += 1
    end
    if self.ver == "3.4"
      self.sess_key = TuyaCodec.ecb(self.key, x, true)
    else
      self.sess_key = crypto.AES_GCM(self.key, self.nonce[0 .. 11]).encrypt(x)
    end
    self.on_ready()
  end

  def nodes()
    var l = [self]
    for c: self.children  l.push(c)  end
    return l
  end
end

#################################################################################
# TuyaScan: discovery of Wi-Fi devices on the local network (like tinytuya scan)
# Instantiated on demand (TuyaScan), released at the end: nothing in RAM the rest of the time.
#################################################################################
#@ solidify:TuyaScan,weak
class TuyaScan
  static var PORTS = [6666, 6667, 7000]     # 3.1 in clear text, 3.3 encrypted, 3.5 (app)
  static var REQUEST_EVERY = 6000           # ms between two requests to 3.5 devices
  var socks                   # list of udp
  var found                   # {"id": {"id", "ip", "version", "product_key"}}
  var t_end, t_req, ip

  def init(ms)
    self.socks = []
    self.found = {}
    for p: self.PORTS
      var u = udp()
      if u.begin("", p)
        self.socks.push(u)
      else
        tasmota.log(f"TUY: discovery: UDP port {p} unavailable", 2)
      end
    end
    self.t_end = tasmota.millis() + ms
    self.t_req = 0
    self.ip = TuyaScan.local_ip()
  end

  # IP address of the gateway: Ethernet, otherwise Wi-Fi; "" without network
  static def local_ip()
    var e = tasmota.eth()
    var ip = (e != nil) ? str(e.find("ip", "")) : ""
    if ip == "" || ip == "0.0.0.0"
      var w = tasmota.wifi()
      ip = (w != nil) ? str(w.find("ip", "")) : ""
    end
    return (ip == "0.0.0.0") ? "" : ip
  end

  # called every 50 ms; false when the discovery is over
  def loop()
    var now = tasmota.millis()
    if now >= self.t_req && size(self.socks) > 0
      self.t_req = now + self.REQUEST_EVERY
      self.request()
    end
    for u: self.socks
      var i = 0
      while i < 8
        var pkt = u.read()
        if pkt == nil  break  end
        self.handle(pkt, u.remote_ip)
        i += 1
      end
    end
    return now < self.t_end
  end

  # 3.5 devices only announce themselves on request: 6699 REQ_DEVINFO (0x25) frame broadcast
  # on port 7000, like the Tuya app and tinytuya scan
  def request()
    import json
    var q = bytes().fromstring(json.dump({"from": "app", "ip": self.ip}))
    self.socks[0].send("255.255.255.255", 7000, TuyaCodec.frame_6699(0, 0x25, q, TuyaCodec.UDP_KEY))
  end

  def handle(pkt, rip)
    var m
    try
      m = TuyaCodec.decode_udp(pkt)
    except .. as e, msg
      return
    end
    if m == nil || m.contains("from")  return  end     # our own request
    var id = m.find("gwId", m.find("devId"))
    if id == nil  return  end
    id = str(id)
    var ip = m.find("ip")
    if ip == nil || ip == ""  ip = rip  end
    self.found[id] = {"id": id, "ip": str(ip), "version": str(m.find("version", "3.3")), "product_key": m.find("productKey")}
  end

  def result()
    var l = []
    for d: self.found  l.push(d)  end
    return l
  end

  def close()
    for u: self.socks  u.close()  end
    self.socks = []
  end
end

#################################################################################
# TuyaImport: tinytuya devices (devices.json) or cloud devices -> tuya.json entries
# Static functions only.
#################################################################################
#@ solidify:TuyaImport,weak
class TuyaImport
  # driver type -> virtual Matter endpoint type
  static var MATTER_TYPES = {"relay": "v_relay", "relay_power": "v_relay_power", "light0": "v_light0",
                             "light1": "v_light1", "light2": "v_light2", "light3": "v_light3",
                             "fan": "v_fan", "temp": "v_temp", "humidity": "v_humidity"}
  static var MAX_OBJECT = 8192      # bytes: beyond this, the JSON object is skipped (RAM)

  # calls cb(object) for each JSON object found at brace depth `level` (nil: 0), the file being
  # read in 512-byte chunks: tinytuya's devices.json (an array, level 0) can exceed the free RAM,
  # and /tuya.json ({"devices": [...]}, level 1) must not be loaded in one go either
  static def each_object(fname, cb, level)
    import json
    var lvl = (level != nil) ? level : 0
    var f = open(fname, "r")
    var depth = 0
    var in_str = false
    var esc = false
    var acc = nil                 # bytes of the current object, nil outside an object
    var skip = false
    var count = 0
    try
      while true
        var b = f.readbytes(512)
        if b == nil || size(b) == 0  break  end
        var start = 0
        var sz = size(b)
        var i = 0
        while i < sz
          var c = b[i]
          if in_str
            if esc
              esc = false
            elif c == 0x5C
              esc = true
            elif c == 0x22
              in_str = false
            end
          elif c == 0x22
            in_str = true
          elif c == 0x7B
            if depth == lvl  acc = bytes()  start = i  skip = false  end
            depth += 1
          elif c == 0x7D
            depth -= 1
            if depth == lvl
              if acc != nil
                acc .. b[start .. i]
                var o = json.load(acc.asstring())
                acc = nil
                if o != nil  cb(o)  count += 1  end
              end
              skip = false
            end
          end
          i += 1
        end
        if acc != nil
          acc .. b[start ..]
          if size(acc) > TuyaImport.MAX_OBJECT
            acc = nil
            skip = true
            tasmota.log("TUY: import: JSON object too big, ignored", 2)
          end
        end
      end
    except .. as e, m
      f.close()
      raise e, m
    end
    f.close()
    return count
  end

  # {"20": {"code": "switch_led", ...}} -> {"switch_led": 20}
  static def codes(mapping)
    var c = {}
    if type(mapping) != 'instance'  return c  end
    for dp: mapping.keys()
      var m = mapping[dp]
      if type(m) != 'instance'  continue  end
      var n = int(dp)
      if str(n) == str(dp) && m.find("code") != nil  c[m["code"]] = n  end
    end
    return c
  end

  static def values(mapping, dp)
    var m = (type(mapping) == 'instance') ? mapping.find(str(dp)) : nil
    var v = (m != nil) ? m.find("values") : nil
    return (type(v) == 'instance' && classname(v) == 'map') ? v : {}
  end

  static def dtype(mapping, dp)
    import string
    var m = (type(mapping) == 'instance') ? mapping.find(str(dp)) : nil
    return (m != nil) ? string.tolower(str(m.find("type", ""))) : ""
  end

  # divider of an integer DP: 10^scale (and mA -> A for the current)
  static def div(mapping, dp, ma)
    var v = TuyaImport.values(mapping, dp)
    var d = 1
    var s = int(v.find("scale", 0))
    while s > 0  d *= 10  s -= 1  end
    if ma && v.find("unit") == "mA"  d *= 1000  end
    return d
  end

  # Matter endpoint name: 32 bytes at most, without splitting a UTF-8 character
  static def ep_name(s)
    var b = bytes().fromstring(s)
    if size(b) <= 32  return s  end
    var n = 32
    while n > 0 && (b[n] & 0xC0) == 0x80  n -= 1  end
    return b[0 .. n - 1].asstring()
  end

  # Matter bindings and sensor readings deduced from the Tuya category and the DP codes
  # -> [matter (list), sensors (map)]
  static def auto(name, category, mapping)
    var c = TuyaImport.codes(mapping)
    var matter = []
    var sensors = {}
    var cat = str(category)
    var fan_cat = (cat == "fs" || cat == "fsd" || cat == "fskg")
    var speed = c.find("fan_speed", c.find("fan_speed_percent"))
    if fan_cat || speed != nil
      # fan: on/off + integer speed; enumerated speed: on/off only
      var on = c.find("switch", c.find("fan_switch", c.find("switch_fan")))
      if on != nil
        if speed != nil && TuyaImport.dtype(mapping, speed) == "integer"
          var v = TuyaImport.values(mapping, speed)
          matter.push({"ep": TuyaImport.ep_name(name), "type": "fan", "dp": on, "dp_speed": speed,
                       "speed_min": int(v.find("min", 1)), "speed_max": int(v.find("max", 6))})
        else
          matter.push({"ep": TuyaImport.ep_name(name), "type": "relay", "dp": on})
        end
      end
      var light = c.find("light", c.find("switch_led"))
      if light != nil  matter.push({"ep": TuyaImport.ep_name("Lumière " + name), "type": "light0", "dp": light})  end
      return [matter, sensors]
    end
    var led = c.find("switch_led")
    if led != nil
      # light: colour (v2) > colour temperature (v2) > dimmer > on/off
      var b = {"ep": TuyaImport.ep_name(name), "type": "light0", "dp": led}
      var bri = c.find("bright_value_v2", c.find("bright_value"))
      if bri != nil
        var v = TuyaImport.values(mapping, bri)
        b["type"] = "light1"
        b["dp_bri"] = bri
        b["bri_min"] = int(v.find("min", 10))
        b["bri_max"] = int(v.find("max", 1000))
        if c.contains("work_mode")  b["dp_mode"] = c["work_mode"]  end
        if c.contains("colour_data_v2")
          b["type"] = "light3"
          b["dp_colour"] = c["colour_data_v2"]
        elif c.contains("temp_value_v2")
          b["type"] = "light2"
          b["dp_ct"] = c["temp_value_v2"]
        end
      end
      matter.push(b)
      return [matter, sensors]
    end
    # switches and plugs: switch, switch_1 ... switch_8; plug with metering: relay_power
    var sw = []
    if c.contains("switch")  sw.push(["", c["switch"]])  end
    var i = 1
    while i <= 8
      var k = f"switch_{i}"
      if c.contains(k)  sw.push([f" {i}", c[k]])  end
      i += 1
    end
    var pw = c.find("cur_power")
    if size(sw) == 1 && pw != nil
      var b = {"ep": TuyaImport.ep_name(name), "type": "relay_power", "dp": sw[0][1],
               "dp_power": pw, "div_power": TuyaImport.div(mapping, pw, false)}
      var vo = c.find("cur_voltage")
      if vo != nil  b["dp_voltage"] = vo  b["div_voltage"] = TuyaImport.div(mapping, vo, false)  end
      var cu = c.find("cur_current")
      if cu != nil  b["dp_current"] = cu  b["div_current"] = TuyaImport.div(mapping, cu, true)  end
      matter.push(b)
    else
      for x: sw  matter.push({"ep": TuyaImport.ep_name(name + x[0]), "type": "relay", "dp": x[1]})  end
    end
    # temperature and humidity sensors
    var tc = c.find("va_temperature", c.find("temp_current"))
    var hc = c.find("va_humidity", c.find("humidity_value"))
    if size(matter) == 0 && tc != nil
      matter.push({"ep": TuyaImport.ep_name(name), "type": "temp", "dp": tc, "div": TuyaImport.div(mapping, tc, false)})
    end
    if size(matter) <= 1 && hc != nil
      matter.push({"ep": TuyaImport.ep_name(name + " humidité"), "type": "humidity", "dp": hc, "div": TuyaImport.div(mapping, hc, false)})
    end
    # energy meters: all integer measurements with a unit
    if cat == "zndb" || cat == "dlq"
      for code: c.keys()
        var dp = c[code]
        var v = TuyaImport.values(mapping, dp)
        if TuyaImport.dtype(mapping, dp) == "integer" && v.find("unit", "") != ""
          sensors[code] = [dp, TuyaImport.div(mapping, dp, false), v["unit"]]
        end
      end
    end
    return [matter, sensors]
  end

  # tinytuya or cloud device -> tuya.json entry (nil without a local key)
  # scan: {"id": TuyaScan result} for the IP and the version
  static def entry(d, scan)
    var id = d.find("id")
    var key = d.find("key", d.find("local_key"))
    if id == nil || key == nil || key == ""  return nil  end
    id = str(id)
    var name = str(d.find("name", id))
    var s = scan.find(id)
    var ip = d.find("ip")
    ip = (ip == nil) ? "" : str(ip)
    if ip == "" && s != nil  ip = s["ip"]  end
    var ver = d.find("version")
    ver = (ver == nil) ? "" : str(ver)
    if ver == "" && s != nil  ver = s["version"]  end
    var e = {"name": name, "id": id, "key": key, "ip": ip, "version": ver}   # "": unknown
    var a = TuyaImport.auto(name, d.find("category"), d.find("mapping"))
    var c = TuyaImport.codes(d.find("mapping"))
    if size(a[0]) > 0  e["matter"] = a[0]  end
    if size(a[1]) > 0  e["sensors"] = a[1]  end
    if size(c) > 0  e["codes"] = c  end
    if d.find("sub") == true
      e.remove("key")
      e.remove("ip")
      e.remove("version")
      e["cid"] = str(d.find("node_id", ""))
      e["parent"] = str(d.find("parent", d.find("gateway_id", "")))
    elif ip == ""
      e["enabled"] = false                    # unknown IP: to be completed (discovery)
    end
    return e
  end

  # merges the entries into conf; an already configured device (same id) keeps its bindings,
  # only its key, IP and version are updated -> {"Added": [], "Updated": [], "Skipped": []}
  static def merge(conf, entries)
    var r = {"Added": [], "Updated": [], "Skipped": []}
    var devs = conf["devices"]
    for e: entries
      if e.contains("cid") continue end
      var i = TuyaImport.find(devs, e["id"])
      if i == nil
        if e["version"] == ""  e["version"] = "3.3"  end
        devs.push(e)
        r["Added"].push(e["name"])
      else
        var cur = devs[i]
        cur["key"] = e["key"]
        if e["ip"] != ""
          if cur.find("ip", "") == ""  cur.remove("enabled")  end
          cur["ip"] = e["ip"]
        end
        if e["version"] != ""  cur["version"] = e["version"]  end
        if !cur.contains("codes") && e.contains("codes")  cur["codes"] = e["codes"]  end
        r["Updated"].push(cur.find("name", e["id"]))
      end
    end
    # sub-devices: attached to their gateway if it is configured
    for e: entries
      if !e.contains("cid") continue end
      var i = TuyaImport.find(devs, e["parent"])
      if i == nil || e["cid"] == ""
        r["Skipped"].push(e["name"])
        continue
      end
      var gw = devs[i]
      if !gw.contains("children")  gw["children"] = []  end
      var known = false
      for ch: gw["children"]
        if str(ch.find("cid")) == e["cid"]  known = true  end
      end
      e.remove("parent")
      if known
        r["Updated"].push(e["name"])
      else
        gw["children"].push(e)
        r["Added"].push(e["name"])
      end
    end
    return r
  end

  # index of a device by id or by name (case-insensitive), or nil
  static def find(devs, ref)
    import string
    if ref == nil  return nil  end
    var r = string.tolower(str(ref))
    var i = 0
    while i < size(devs)
      var d = devs[i]
      if str(d.find("id")) == str(ref) || string.tolower(str(d.find("name", ""))) == r  return i  end
      i += 1
    end
    return nil
  end
end

#################################################################################
# TuyaCloud: local keys and DPs from the Tuya cloud (OpenAPI, like tinytuya wizard)
# One HTTPS request per step, instantiated on demand. Credentials are saved by TuyaLocal, on request only.
#################################################################################
#@ solidify:TuyaCloud,weak
class TuyaCloud
  static var HOSTS = {"eu": "openapi.tuyaeu.com", "we": "openapi-weaz.tuyaeu.com", "us": "openapi.tuyaus.com",
                      "ue": "openapi-ueaz.tuyaus.com", "cn": "openapi.tuyacn.com", "in": "openapi.tuyain.com",
                      "sg": "openapi-sg.iotbing.com"}
  static var EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  var host, key, secret, token
  var ids, i, step, cur, out

  def init(region, key, secret, ids)
    import string
    self.host = self.HOSTS.find(string.tolower(str(region)))
    if self.host == nil  raise "tuya_error", "unknown region (eu, we, us, ue, cn, in, sg)"  end
    if key == nil || key == "" || secret == nil || secret == ""  raise "tuya_error", "Access ID and Access Secret required"  end
    self.key = key
    self.secret = secret
    self.ids = ids
    self.i = 0
    self.step = 0
    self.out = []
  end

  # Tuya OpenAPI signature (new algorithm), GET request without body or signed header:
  # HMAC-SHA256(secret, client_id + [access_token] + t + "GET\n" + sha256("") + "\n\n" + path)
  static def sign(key, secret, token, t, path)
    import crypto
    import string
    var s = key + (token != nil ? token : "") + t + "GET\n" + TuyaCloud.EMPTY_SHA256 + "\n\n" + path
    return string.toupper(crypto.HMAC_SHA256(bytes().fromstring(secret)).update(bytes().fromstring(s)).out().tohex())
  end

  static def now_ms()
    var u = tasmota.rtc()["utc"]
    if u < 1600000000  raise "tuya_error", "time not synchronized (NTP)"  end
    return str(u) + "000"
  end

  # integers of more than 9 digits -> strings. Every cloud response carries the time in ms
  # ("t":1794092132086), which exceeds Berry's 32-bit integers: json.load would return nil.
  # Only the values of a key ("key":123...) are touched, not the escaped JSON of "values".
  static def quote_big(s)
    import string
    var out = []
    var p = 0
    var n = size(s)
    var i = string.find(s, "\":")
    while i >= 0
      var j = i + 2
      var k = (j < n && s[j] == "-") ? j + 1 : j
      while k < n && s[k] >= "0" && s[k] <= "9"  k += 1  end
      if k - j > 9 && (i == 0 || s[i - 1] != "\\")
        out.push(s[p .. j - 1])
        out.push("\"" + s[j .. k - 1] + "\"")
        p = k
      end
      i = string.find(s, "\":", k)
    end
    if p == 0  return s  end
    out.push(s[p ..])
    return out.concat()
  end

  def request(path)
    import json
    var t = TuyaCloud.now_ms()
    var wc = webclient()
    wc.begin("https://" + self.host + path)
    wc.add_header("client_id", self.key)
    wc.add_header("sign", TuyaCloud.sign(self.key, self.secret, self.token, t, path))
    wc.add_header("t", t)
    wc.add_header("sign_method", "HMAC-SHA256")
    wc.add_header("mode", "cors")
    if self.token != nil
      wc.add_header("access_token", self.token)
    else
      wc.add_header("secret", self.secret)    # like tinytuya for the token request
    end
    var code = wc.GET()
    var s = (code == 200) ? wc.get_string() : nil
    wc.close()
    if s == nil  raise "tuya_error", f"Tuya cloud: HTTP {code}"  end
    var m = json.load(TuyaCloud.quote_big(s))
    s = nil
    if m == nil || m.find("success") != true
      var why = (m != nil) ? m.find("msg", m.find("code")) : "invalid response"
      raise "tuya_error", f"Tuya cloud: {why}"
    end
    return m["result"]
  end

  # specification "status" and "functions" -> mapping in tinytuya's format
  static def mapping(r)
    import json
    var dps = {}
    for k: ["status", "functions"]
      for m: r.find(k, [])
        var dp = m.find("dp_id")
        if dp == nil  continue  end
        var ks = str(dp)
        if dps.contains(ks)  continue  end
        var v = m.find("values")
        if type(v) == 'string'
          var j = json.load(v)
          if j != nil  v = j  end
        end
        dps[ks] = {"code": m.find("code"), "type": m.find("type"), "values": v}
      end
    end
    return dps
  end

  # one request per call: token, then for each device its details (key) and specifications (DPs)
  # -> true while requests remain
  def next()
    if self.token == nil
      self.token = self.request("/v1.0/token?grant_type=1")["access_token"]
      return true
    end
    if self.i >= size(self.ids)  return false  end
    var id = self.ids[self.i]
    if self.step == 0
      var d = self.request("/v1.0/devices/" + id)
      self.cur = {"id": id, "name": d.find("name", id), "key": d.find("local_key"),
                  "category": d.find("category"), "sub": d.find("sub")}
      self.step = 1
    else
      try
        self.cur["mapping"] = TuyaCloud.mapping(self.request("/v1.1/devices/" + id + "/specifications"))
      except .. as e, m
        tasmota.log(f"TUY: cloud: no DP for {id}: {m}", 2)
      end
      self.out.push(self.cur)
      self.cur = nil
      self.step = 0
      self.i += 1
    end
    return self.i < size(self.ids)
  end
end

#################################################################################
# TuyaWeb: Configuration -> Tuya Local page (/tuya). Static functions only.
# Layout of Tasmota's pages (like Matter's): 320 px text, small table headers,
# HTML pictograms for the actions. Interface in English, like Tasmota.
#################################################################################
#@ solidify:TuyaWeb,weak
class TuyaWeb
  # device state (TuyaLocal.state_of) -> pictogram and label
  static var STATES = {"connected": ["&#x1F7E2;", "connected"], "disconnected": ["&#x1F534;", "disconnected"],
                       "disabled": ["&#x26AA;", "disabled"], "ignored": ["&#x26A0;", "incomplete, ignored"],
                       "stopped": ["&#x23F8;&#xFE0F;", "driver not running"]}
  static var REGIONS = [["eu", "Central Europe"], ["we", "Western Europe"], ["us", "Western America"],
                        ["ue", "Eastern America"], ["cn", "China"], ["in", "India"], ["sg", "Singapore"]]

  static def esc(s)
    import webserver
    return webserver.html_escape(str(s))
  end

  static def p(txt)
    import webserver
    webserver.content_send("<p style='width:320px;'>" + txt + "</p>")
  end

  static def legend(title)
    import webserver
    webserver.content_send("<fieldset><legend><b>&nbsp;" + title + "&nbsp;</b></legend><p></p>")
  end

  static def th(cols)
    var s = "<tr>"
    for c: cols  s += "<td width='" + str(c[1]) + "' style='font-size:smaller;'>" + c[0] + "</td>"  end
    return s + "</tr>"
  end

  static def button()
    import webserver
    webserver.content_send("<p></p><form id=tuya action='tuya' style='display: block;' method='get'><button>&#x1F50C; Tuya Local</button></form>")
  end

  # button of the main page, in the sensor area that the browser refreshes: greyed out while the
  # driver waits for Zigbee, the network or Matter (like Zigbee's buttons), nothing if disabled
  static def main_button(drv)
    var st = drv.state()
    if st == "disabled"  return  end
    if drv.running
      tasmota.web_send("<tr><td colspan=2><a href='/tuya'><button>&#x1F50C; Tuya Local</button></a></td></tr>")
    else
      tasmota.web_send("{s}Tuya Local{m}" + TuyaWeb.esc(st) + "{e}" +
                       "<tr><td colspan=2><button disabled style='background:var(--c_frm)'>&#x23F3; Tuya Local</button></td></tr>")
    end
  end

  # enable checkbox, like Matter's page
  static def enable(drv)
    import webserver
    TuyaWeb.legend("Tuya Local")
    var on = drv.enabled()
    webserver.content_send("<form action='/tuya' method='post'><p><label><input type='checkbox' name='enable'" +
                           (on ? " checked" : "") + "><b>Tuya Local enable</b></label></p>")
    var st = drv.state()
    var icon = drv.running ? "&#x1F7E2;" : (st == "disabled" ? "&#x26AA;" : "&#x23F3;")
    TuyaWeb.p(icon + " " + TuyaWeb.esc(st))
    webserver.content_send("<button name='enable_save' class='button bgrn'>&#x1F4BE; Save</button></form></fieldset><p></p>")
  end

  static def page(drv)
    import webserver
    if !webserver.check_privileged_access()  return nil  end
    webserver.content_start("Tuya Local")
    webserver.content_send_style()
    if drv.web_msg != nil
      webserver.content_send("<p style='width:320px;text-align:center'><b>" + TuyaWeb.esc(drv.web_msg) + "</b></p>")
      drv.web_msg = nil
    end
    if webserver.has_arg("edit")
      TuyaWeb.edit(drv, webserver.arg("edit"))
    else
      TuyaWeb.enable(drv)
      TuyaWeb.devices(drv)
      TuyaWeb.matter(drv)
      TuyaWeb.scan(drv)
      TuyaWeb.imports(drv)
    end
    webserver.content_button(webserver.BUTTON_CONFIGURATION)
    webserver.content_stop()
    tasmota.gc()                              # give the page's garbage back at once
  end

  static def devices(drv)
    import webserver
    TuyaWeb.legend("Tuya devices")
    webserver.content_send("<table style='width:100%'>" +
                           TuyaWeb.th([["Name", 130], ["IP", 100], ["Ver.", 30], ["", 20], ["", 20]]))
    var n = [0]
    try
      drv.each_device(def (c)                 # one entry at a time: tuya.json is never loaded whole
        var id = str(c.find("id", ""))
        var st = TuyaWeb.STATES.find(drv.state_of(c), ["?", "?"])
        webserver.content_send("<tr><td>" + TuyaWeb.esc(c.find("name", id)) + "</td><td style='font-size:smaller;'>" +
                               TuyaWeb.esc(c.find("ip", "")) + "</td><td style='font-size:smaller;'>" + TuyaWeb.esc(c.find("version", "")) +
                               "</td><td title='" + st[1] + "'>" + st[0] + "</td><td><a href='/tuya?edit=" + TuyaWeb.esc(id) +
                               "' title='Edit' style='text-decoration:none;'>&#x1F4DD;</a></td></tr>")
        n[0] += 1
      end)
    except .. as e, m
      webserver.content_send("</table>")
      TuyaWeb.p("&#x26A0; " + TuyaWeb.esc(m))
      n = nil
    end
    if n != nil
      webserver.content_send("</table>")
      if n[0] == 0  TuyaWeb.p("No device: run a discovery, then import the local keys.")  end
    end
    webserver.content_send("<p></p><form action='/tuya' method='get'><input type='hidden' name='edit' value=''><button>&#x2795; Add device</button></form>")
    webserver.content_send("<p></p><form action='/tuya' method='post'><button name='reload'>&#x1F504; Reload tuya.json</button></form></fieldset><p></p>")
  end

  static def edit(drv, ref)
    import webserver
    import json
    var d = nil
    if ref != ""
      var found = []
      drv.each_device(def (c)
        if size(found) == 0 && TuyaImport.find([c], ref) != nil  found.push(c)  end
      end)
      if size(found) > 0  d = found[0]  end
    end
    if d == nil
      ref = ""
      d = {"name": "", "id": "", "key": "", "ip": "", "version": "3.3", "matter": [{"ep": "", "type": "relay", "dp": 1}]}
    elif d.contains("key")
      d["key"] = "***"
    end
    TuyaWeb.legend((ref == "") ? "New Tuya device" : "Tuya device")
    TuyaWeb.p("JSON configuration (see the documentation). A <code>***</code> key keeps the saved key.")
    webserver.content_send("<form action='/tuya' method='post'><input type='hidden' name='ref' value='" + TuyaWeb.esc(ref) + "'>")
    webserver.content_send("<textarea name='json' style='width:100%;box-sizing:border-box;font-family:monospace;font-size:smaller'>" +
                           TuyaWeb.esc(json.dump(d, "format")) + "</textarea>")
    webserver.content_send("<button name='save' class='button bgrn'>&#x1F4BE; Save</button></form>")
    if ref != ""
      var on = d.find("enabled", true) != false
      webserver.content_send("<p></p><form action='/tuya' method='post'><input type='hidden' name='ref' value='" + TuyaWeb.esc(ref) +
                             "'><input type='hidden' name='active' value='" + (on ? "0" : "1") + "'><button>" +
                             (on ? "&#x23F8;&#xFE0F; Disable (kept in tuya.json)" : "&#x25B6;&#xFE0F; Enable") + "</button></form>")
      webserver.content_send("<p></p><form action='/tuya' method='post' onsubmit='return confirm(\"Delete this device?\")'>" +
                             "<input type='hidden' name='ref' value='" + TuyaWeb.esc(ref) + "'><button name='del' class='button bred'>&#x1F525; Delete</button></form>")
    end
    webserver.content_send("<p></p><form action='/tuya' method='get'><button>&#x21A9; Back</button></form></fieldset><p></p>")
  end

  # one row per binding, like the device list, with a checkbox: created endpoint (number),
  # missing endpoint, or binding disabled in tuya.json; create, disable or enable the selection
  static def matter(drv)
    import webserver
    TuyaWeb.legend("Matter endpoints")
    var rows = drv.running ? drv.matter_status() : nil
    if !drv.running
      TuyaWeb.p("&#x23F8;&#xFE0F; Tuya Local is not running.")
    elif rows == nil
      TuyaWeb.p("&#x26A0; Matter is not enabled.")
    else
      var off = drv.matter_disabled()
      if size(rows) == 0 && size(off) == 0
        TuyaWeb.p("No binding: add Tuya devices first.")
        webserver.content_send("</fieldset><p></p>")
        return
      end
      var nmiss = 0
      for r: rows
        if r[1] == nil  nmiss += 1  end
      end
      var all = (size(rows) + size(off) > 1) ? "<input type='checkbox' title='all' onclick='for(var c of this.form.querySelectorAll(\"input[name^=m]\"))c.checked=this.checked'>" : ""
      webserver.content_send("<form action='/tuya' method='post'><table style='width:100%'>" +
                             TuyaWeb.th([[all, 20], ["Endpoint", 140], ["Type", 90], ["", 35]]))
      var i = 0
      var row = def (ep, typ, state)
        webserver.content_send("<tr><td><input type='checkbox' name='m" + str(i) + "' value='" + TuyaWeb.esc(ep) + "'></td><td>" +
                               TuyaWeb.esc(ep) + "</td><td style='font-size:smaller;'>" + TuyaImport.MATTER_TYPES.find(typ, "?") +
                               "</td><td style='font-size:smaller;'>" + state + "</td></tr>")
        i += 1
      end
      for r: rows
        row(r[0].ep, r[0].type, r[1] != nil ? "<span title='endpoint " + str(r[1]) + "'>&#x2705;" + str(r[1]) + "</span>" :
                                              "<span title='missing'>&#x26A0;</span>")
      end
      for o: off  row(o[0], o[1], "<span title='disabled'>&#x23F8;&#xFE0F;</span>")  end
      webserver.content_send("</table><input type='hidden' name='mn' value='" + str(i) + "'>")
      var txt = []
      if nmiss > 0
        txt.push("&#x26A0; " + str(nmiss) + " missing")
      elif size(rows) > 0
        txt.push("&#x2705; Every active binding has its Matter endpoint")
      end
      if size(off) > 0  txt.push("&#x23F8;&#xFE0F; " + str(size(off)) + " disabled")  end
      TuyaWeb.p(txt.concat("; ") + ". Tick bindings, then:")
      if nmiss > 0
        webserver.content_send("<button name='matter' class='button bgrn' onclick='return confirm(\"Create the selected endpoints and restart?\")'>&#x2795; Create and restart</button><p></p>")
      end
      if size(rows) > 0  webserver.content_send("<button name='m_off'>&#x23F8;&#xFE0F; Disable</button><p></p>")  end
      if size(off) > 0  webserver.content_send("<button name='m_on'>&#x25B6;&#xFE0F; Enable</button>")  end
      webserver.content_send("</form>")
    end
    webserver.content_send("</fieldset><p></p>")
  end

  static def scan(drv)
    import webserver
    TuyaWeb.legend("Network discovery")
    if drv.scan != nil
      TuyaWeb.p("&#x23F3; Discovery in progress...")
      webserver.content_send("<script>setTimeout(function(){location.href='/tuya'},4000)</script>")
    else
      webserver.content_send("<form action='/tuya' method='post'><button name='scan'>&#x1F50D; Discover devices (20 s)</button></form>")
    end
    if drv.scan_result != nil
      var conf = {"devices": []}             # ids only, entry by entry
      try
        drv.each_device(def (c)  conf["devices"].push({"id": c.find("id"), "name": c.find("name")})  end)
      except .. as e, m
      end
      webserver.content_send("<p></p><table style='width:100%'>" + TuyaWeb.th([["Id", 160], ["IP", 100], ["Ver.", 30], ["", 20]]))
      for r: drv.scan_result
        var known = (TuyaImport.find(conf["devices"], r["id"]) != nil) ? "<span title='configured'>&#x2705;</span>" : "<span title='new'>&#x1F195;</span>"
        webserver.content_send("<tr><td style='font-size:smaller;'>" + TuyaWeb.esc(r["id"]) + "</td><td style='font-size:smaller;'>" + TuyaWeb.esc(r["ip"]) +
                               "</td><td style='font-size:smaller;'>" + TuyaWeb.esc(r["version"]) + "</td><td>" + known + "</td></tr>")
      end
      webserver.content_send("</table>")
      if size(drv.scan_result) == 0  TuyaWeb.p("No device found.")  end
    end
    webserver.content_send("</fieldset><p></p>")
  end

  static def imports(drv)
    import webserver
    var heap = tasmota.memory().find("heap_free", 0)
    TuyaWeb.legend("Import local keys")
    TuyaWeb.p("From the <code>devices.json</code> of <code>tinytuya wizard</code>, uploaded with Tools &#x2192; Manage File system. " +
              "Without <i>all</i>, only the devices found by the discovery or already configured are imported.")
    webserver.content_send("<form action='/tuya' method='post'><p><b>File</b><br><input name='file' value='/devices.json'></p>" +
                           "<p><label><input type='checkbox' name='all'> all</label></p>" +
                           "<button name='import'>&#x1F4E5; Import file</button></form>")
    var c = drv.cloud_saved()
    webserver.content_send("<hr>")
    TuyaWeb.p("Or from the Tuya cloud, for the devices found by the discovery (Tuya IoT project, as for " +
              "<code>tinytuya wizard</code>). Free memory: " + str(heap) + " KB, " + str(drv.CLOUD_MIN_HEAP) + " KB needed.")
    var reg = (c != nil) ? str(c.find("region", "eu")) : "eu"
    var opts = ""
    for r: TuyaWeb.REGIONS
      opts += "<option value='" + r[0] + "'" + (r[0] == reg ? " selected" : "") + ">" + r[1] + "</option>"
    end
    webserver.content_send("<form action='/tuya' method='post'><p><b>Region</b><br><select name='region'>" + opts + "</select></p>" +
                           "<p><b>Access ID</b><br><input name='cid' placeholder='Access ID' value='" +
                           TuyaWeb.esc(c != nil ? c.find("id", "") : "") + "'></p>" +
                           "<p><b>Access Secret</b><br><input name='secret' type='password' placeholder='" +
                           (c != nil ? "Access Secret (saved, leave empty)" : "Access Secret") + "'></p>" +
                           "<p><label><input type='checkbox' name='keep'" + (c != nil ? " checked" : "") +
                           "> save credentials (<code>" + drv.CLOUD_CONF + "</code>)</label></p>" +
                           "<button name='cloud'>&#x2601;&#xFE0F; Import from cloud</button></form>")
    webserver.content_send("</fieldset><p></p>")
  end

  # forms (POST /tuya) -> action, message for the next page, redirect
  static def post(drv)
    import webserver
    import json
    if !webserver.check_privileged_access()  return nil  end
    var msg = nil
    var rst = false
    try
      if webserver.has_arg("save")
        var d = json.load(webserver.arg("json"))
        if type(d) != 'instance' || classname(d) != 'map'  raise "tuya_error", "invalid JSON"  end
        var ref = webserver.arg("ref")
        msg = "Saved: " + drv.save_device(d, ref != "" ? ref : nil)
      elif webserver.has_arg("del")
        msg = "Deleted: " + drv.del_device(webserver.arg("ref"))
      elif webserver.has_arg("reload")
        if !drv.running  raise "tuya_error", "Tuya Local is not running: " + drv.state()  end
        drv.reload()
        msg = "tuya.json reloaded"
      elif webserver.has_arg("enable_save")
        drv.set_enabled(webserver.has_arg("enable"))
        msg = drv.enabled() ? "Tuya Local enabled" : "Tuya Local disabled"
      elif webserver.has_arg("scan")
        msg = drv.start_scan(20)
      elif webserver.has_arg("import")
        msg = drv.summary(drv.import_file(webserver.arg("file"), webserver.has_arg("all") ? "all" : nil))
      elif webserver.has_arg("cloud")
        msg = drv.cloud_start({"region": webserver.arg("region"), "id": webserver.arg("cid"),
                               "secret": webserver.arg("secret"), "save": webserver.has_arg("keep")})
      elif webserver.has_arg("matter") || webserver.has_arg("m_off") || webserver.has_arg("m_on")
        var sel = []
        var n = int(webserver.arg("mn"))
        var i = 0
        while i < n
          if webserver.has_arg("m" + str(i))  sel.push(webserver.arg("m" + str(i)))  end
          i += 1
        end
        if size(sel) == 0  raise "tuya_error", "no endpoint selected"  end
        if webserver.has_arg("matter")
          var added = drv.matter_create(sel)
          if size(added) == 0  raise "tuya_error", "no missing endpoint selected"  end
          msg = "Matter endpoints created: " + str(size(added)) + ", restarting"
          rst = true
        else
          var on = webserver.has_arg("m_on")
          msg = (on ? "Enabled: " : "Disabled: ") + drv.set_active(sel, on, "ep").concat(", ")
        end
      elif webserver.has_arg("active")
        var on = webserver.arg("active") == "1"
        msg = (on ? "Enabled: " : "Disabled: ") + drv.set_active([webserver.arg("ref")], on, "dev").concat(", ")
      end
    except .. as e, m
      msg = "Error: " + str(m)
    end
    drv.web_msg = msg
    tasmota.gc()
    webserver.redirect(rst ? "/?rst=" : "/tuya")
  end
end

#################################################################################
# TuyaLocal: Tasmota driver
#################################################################################
#@ solidify:TuyaLocal,weak
class TuyaLocal
  static var CONFIG = "/tuya.json"
  static var CLOUD_CONF = "/tuya_cloud.json"   # cloud credentials, if saved (never in tuya.json)
  static var SYNC_RETRY = 30000   # ms between two resends to Matter endpoints that refused
  # minimum free memory (KB) to start: a discovery, a file import, a cloud import
  # (HTTPS: Tasmota's TLS client alone reserves 16 KB)
  static var SCAN_MIN_HEAP = 15
  static var IMPORT_MIN_HEAP = 20
  static var CLOUD_MIN_HEAP = 35
  static var START_MIN_HEAP = 45  # free memory (KB) needed to start the driver at boot
  static var CONF_MIN_HEAP = 30   # free memory (KB) needed to load the whole tuya.json (to modify it)
  static var LABELS = {"Added": "added", "Updated": "updated", "Skipped": "skipped"}
  var devices                 # list of TuyaDevice
  var by_ep                   # {lower-case Matter endpoint name: TuyaBinding}
  var t_sync                  # millis of the last resend
  var scan, scan_result       # running discovery (TuyaScan) and last result (list)
  var cloud, cloud_t          # running cloud import (TuyaCloud) and millis of the next request
  var web_msg                 # message to show on the web page
  var running                 # true once started: tuya.json loaded, devices connecting
  var wait                    # why the driver is not started yet ("disabled", "waiting for Zigbee"...)
  var inert                   # true: second instance (old autoexec.be lines), does nothing

  # Instantiated at boot by the firmware (Berry init code, like Matter), with nothing heavy:
  # the driver only starts in every_second(), once enabled and Zigbee, the network and Matter
  # are ready (see start_wait()).
  def init()
    import global
    self.devices = []
    self.by_ep = {}
    self.t_sync = tasmota.millis()
    self.running = false
    self.wait = "starting"
    if global.contains("tuya_local") && global.tuya_local != nil
      self.inert = true
      tasmota.log("TUY: driver already started by the firmware: remove the tuya_local lines from autoexec.be", 1)
      return
    end
    tasmota.add_driver(self)
    tasmota.add_rule("MtrReceived", /v -> self.on_matter(v), self)
    tasmota.add_cmd("TuyaStatus", /cmd, idx, payload -> self.cmd_status(payload))
    tasmota.add_cmd("TuyaSend", /cmd, idx, payload -> self.cmd_send(payload))
    tasmota.add_cmd("TuyaReload", /cmd, idx, payload -> self.cmd_reload())
    tasmota.add_cmd("TuyaConfig", /c, i, p -> self.run_cmd("TuyaConfig", / -> self.masked_conf(p)))
    tasmota.add_cmd("TuyaAdd", /c, i, p -> self.run_cmd("TuyaAdd", / -> self.add_json(p)))
    tasmota.add_cmd("TuyaDel", /c, i, p -> self.run_cmd("TuyaDel", / -> self.del_device(self.trim(str(p)))))
    tasmota.add_cmd("TuyaScan", /c, i, p -> self.run_cmd("TuyaScan", / -> self.start_scan(int(p) > 0 ? int(p) : 20)))
    tasmota.add_cmd("TuyaImport", /c, i, p -> self.run_cmd("TuyaImport", / -> self.import_args(p)))
    tasmota.add_cmd("TuyaCloud", /c, i, p -> self.run_cmd("TuyaCloud", / -> self.cloud_json(p)))
    tasmota.add_cmd("TuyaMatter", /c, i, p -> self.run_cmd("TuyaMatter", / -> self.matter_cmd(p)))
    tasmota.add_cmd("TuyaEnable", /c, i, p -> self.run_cmd("TuyaEnable", / -> self.enable_cmd(p)))
    tasmota.add_cmd("TuyaActive", /c, i, p -> self.run_cmd("TuyaActive", / -> self.active_cmd(p)))
    # web page: the driver starts after the web server, which therefore does not call web_add_handler()
    import webserver
    if webserver.state() > 0  self.web_add_handler()  end
  end

  ###################### start and enable ######################
  # enabled by the checkbox of the web page or TuyaEnable 1 (kept in _persist.json, like a setting)
  def enabled()
    import persist
    return persist.find("tuya_local", false) == true
  end

  # why the driver cannot start yet, or nil when it can
  def start_wait()
    import global
    if !self.enabled()  return "disabled"  end
    if global.contains("zigbee") && global.zigbee != nil && global.zigbee.started() == false
      return "waiting for Zigbee"
    end
    if TuyaScan.local_ip() == ""  return "waiting for the network"  end
    var md = global.contains("matter_device") ? global.matter_device : nil
    # Matter started: its UDP server exists (`started` is declared by Matter_zz_Device but never set)
    if md != nil && md.plugins_config != nil && md.udp_server == nil  return "waiting for Matter"  end
    var h = tasmota.memory().find("heap_free", 0)
    if h < self.START_MIN_HEAP  return f"waiting for memory ({h} KB, {self.START_MIN_HEAP} KB needed)"  end
    return nil
  end

  def every_second()
    if self.running  return  end
    var why = self.start_wait()
    if why != self.wait && why != nil && why != "disabled"  tasmota.log("TUY: " + why, 2)  end
    self.wait = why
    if why == nil
      self.running = true
      tasmota.log("TUY: starting, free memory " + str(tasmota.memory().find("heap_free", 0)) + " KB", 2)
      self.load_config()
    end
  end

  def stop()
    for d: self.devices  d.close("driver disabled")  end
    self.devices = []
    self.by_ep = {}
    self.running = false
    self.wait = "disabled"
  end

  def set_enabled(on)
    import persist
    persist.tuya_local = on
    persist.save()
    if on
      self.wait = "starting"                    # started by every_second() when ready
    elif self.running
      self.stop()
    else
      self.wait = "disabled"
    end
  end

  # "running", "disabled" or what the driver waits for
  def state()
    if self.running  return "running"  end
    return (self.wait != nil) ? self.wait : "starting"
  end

  # TuyaEnable [0|1]
  def enable_cmd(p)
    import string
    var s = string.tolower(self.trim(str(p)))
    if s == "1" || s == "on" || s == "true"
      self.set_enabled(true)
    elif s == "0" || s == "off" || s == "false"
      self.set_enabled(false)
    elif s != ""
      raise "tuya_error", "syntax: TuyaEnable [0|1]"
    end
    return {"Enabled": self.enabled(), "State": self.state()}
  end

  # Configuration -> Tuya Local page
  def web_add_config_button()
    TuyaWeb.button()
  end
  def web_add_handler()
    import webserver
    webserver.on("/tuya", / -> TuyaWeb.page(self), webserver.HTTP_GET)
    webserver.on("/tuya", / -> TuyaWeb.post(self), webserver.HTTP_POST)
  end

  # command -> JSON response {"<command>": result} or {"<command>": {"Error": "..."}}
  def run_cmd(name, f)
    import json
    var r
    try
      r = f()
    except .. as e, m
      r = {"Error": str(m)}
      if e != "tuya_error"  tasmota.log(f"TUY: {name}: {e} {m}", 2)  end
    end
    var o = {}
    o[name] = r
    tasmota.resp_cmnd(json.dump(o))
  end

  # result of a background operation: log, MQTT (RESULT) and web page
  def report(name, r)
    import json
    var o = {}
    o[name] = r
    tasmota.log(f"TUY: {name} {json.dump(r)}", 2)
    tasmota.publish_result(json.dump(o), "RESULT")
    self.web_msg = name + ": " + self.summary(r)
  end

  def summary(r)
    if type(r) != 'instance'  return str(r)  end
    if r.contains("Error")  return "error: " + str(r["Error"])  end
    if r.contains("Devices")  return str(size(r["Devices"])) + " device(s) found"  end
    var l = []
    for k: ["Added", "Updated", "Skipped"]
      if r.contains(k) && size(r[k]) > 0  l.push(self.LABELS[k] + ": " + r[k].concat(", "))  end
    end
    return size(l) > 0 ? l.concat("; ") : "no device imported"
  end

  def check_heap(min)
    var h = tasmota.memory().find("heap_free", 0)
    if h < min  raise "tuya_error", f"not enough free memory: {h} KB, {min} KB needed"  end
  end

  ###################### configuration file ######################
  # /tuya.json -> map; missing or empty: empty configuration; invalid: error (never overwritten)
  # each device entry of /tuya.json, read in chunks: never the whole file in RAM (with an import
  # from the cloud, codes and bindings make it ~1 KB per device, and json.load of the whole file
  # costs ~2 times its size). A missing file gives no entry; an invalid entry is skipped.
  def each_device(cb)
    try
      TuyaImport.each_object(self.CONFIG, cb, 1)
    except "io_error"
    end
  end

  # the whole /tuya.json, only to modify it (save, delete, imports): costly, hence the garbage
  # collection first and the memory guard, which refuses instead of crashing
  def read_conf()
    import json
    tasmota.gc()
    self.check_heap(self.CONF_MIN_HEAP)
    var s
    try
      var f = open(self.CONFIG, "r")
      s = f.read()
      f.close()
    except .. as e, m
      return {"devices": []}
    end
    if s == nil || s == ""  return {"devices": []}  end
    var conf = json.load(s)
    if type(conf) != 'instance' || classname(conf) != 'map'
      raise "tuya_error", f"{self.CONFIG} is not valid JSON: not modified"
    end
    if type(conf.find("devices")) != 'instance'  conf["devices"] = []  end
    return conf
  end

  # writes /tuya.json, the previous version being kept in /tuya.json.bak
  def write_conf(conf)
    import json
    try                                       # copy in chunks, not the whole file in RAM
      var fi = open(self.CONFIG, "r")
      var fb = open(self.CONFIG + ".bak", "w")
      while true
        var b = fi.readbytes(512)
        if b == nil || size(b) == 0  break  end
        fb.write(b)
      end
      fi.close()
      fb.close()
    except .. as e, m
    end
    var fo = open(self.CONFIG, "w")
    fo.write(json.dump(conf, "format"))
    fo.close()
  end

  # TuyaConfig [device]: configuration without the keys
  def masked_conf(ref)
    var conf = self.read_conf()
    for d: conf["devices"]
      if d.contains("key")  d["key"] = "***"  end
    end
    ref = self.trim(str(ref != nil ? ref : ""))
    if ref == ""  return conf  end
    var i = TuyaImport.find(conf["devices"], ref)
    if i == nil  raise "tuya_error", "unknown device"  end
    return conf["devices"][i]
  end

  # TuyaAdd {"name":...,"id":...,"key":...,"ip":...,"version":...,"matter":[...]}
  def add_json(p)
    import json
    var d = json.load(str(p))
    if type(d) != 'instance' || classname(d) != 'map'
      raise "tuya_error", "syntax: TuyaAdd {\"name\":...,\"id\":...,\"key\":...,\"ip\":...,\"version\":...,\"matter\":[...]}"
    end
    return self.save_device(d, nil)
  end

  # adds or replaces a device (designated by ref, otherwise by its id) -> device name.
  # Missing, empty or "***" key: the saved key is kept.
  def save_device(d, ref)
    if str(d.find("name", "")) == "" || str(d.find("id", "")) == ""  raise "tuya_error", "name and id required"  end
    var conf = self.read_conf()
    var devs = conf["devices"]
    var i = TuyaImport.find(devs, ref != nil ? ref : d["id"])
    var k = d.find("key")
    if k == nil || k == "" || k == "***"
      if i == nil || devs[i].find("key") == nil  raise "tuya_error", "local key (key) required"  end
      d["key"] = devs[i]["key"]
    end
    if i == nil
      if TuyaImport.find(devs, d["name"]) != nil || TuyaImport.find(devs, d["id"]) != nil
        raise "tuya_error", "name or id already used"
      end
      devs.push(d)
    else
      devs[i] = d
    end
    self.write_conf(conf)
    self.reload()
    return d["name"]
  end

  # reloads tuya.json if the driver runs (otherwise it is read when it starts)
  def reload()
    if self.running  self.load_config()  end
  end

  # enables or disables, without deleting them, devices, gateway sub-devices or Matter bindings,
  # designated by name (case-insensitive) or id: "enabled": false in tuya.json, then reload.
  # scope "dev": devices and sub-devices only; "ep": bindings (endpoint names) only; nil: devices
  # first, bindings if no device matches -> names changed
  def set_active(names, on, scope)
    import string
    var want = {}
    for n: names
      var k = string.tolower(self.trim(str(n)))
      if k != ""  want[k] = true  end
    end
    var conf = self.read_conf()
    var done = []
    var mark = def (e, label)
      if on  e.remove("enabled")  else  e["enabled"] = false  end
      done.push(label)
    end
    var hit = def (e)
      return want.contains(string.tolower(str(e.find("name", "")))) || want.contains(string.tolower(str(e.find("id", ""))))
    end
    if scope != "ep"
      for d: conf["devices"]
        if hit(d)  mark(d, d.find("name", d.find("id")))  end
        for ch: d.find("children", [])
          if hit(ch)  mark(ch, ch.find("name", ch.find("id")))  end
        end
      end
    end
    if scope == "ep" || (scope == nil && size(done) == 0)
      var eps = def (e)
        for m: e.find("matter", [])
          if want.contains(string.tolower(str(m.find("ep", e.find("name", "")))))  mark(m, m.find("ep", e.find("name")))  end
        end
      end
      for d: conf["devices"]
        eps(d)
        for ch: d.find("children", [])  eps(ch)  end
      end
    end
    if size(done) == 0  raise "tuya_error", "unknown device or endpoint"  end
    self.write_conf(conf)
    self.reload()
    return done
  end

  # TuyaActive <device or endpoint>[,<device or endpoint>...],<0|1>
  def active_cmd(p)
    import string
    var a = string.split(str(p), ",")
    var f = string.tolower(self.trim(a[-1]))
    if size(a) < 2 || (f != "0" && f != "1" && f != "on" && f != "off")
      raise "tuya_error", "syntax: TuyaActive <device or endpoint>[,...],<0|1>"
    end
    var on = (f == "1" || f == "on")
    var names = []
    var i = 0
    while i < size(a) - 1  names.push(a[i])  i += 1  end
    var r = {}
    r[on ? "Enabled" : "Disabled"] = self.set_active(names, on, nil)
    return r
  end

  # TuyaDel <device> -> name of the deleted device
  def del_device(ref)
    var conf = self.read_conf()
    var i = TuyaImport.find(conf["devices"], ref)
    if i == nil  raise "tuya_error", "unknown device"  end
    var name = conf["devices"][i].find("name", ref)
    conf["devices"].remove(i)
    self.write_conf(conf)
    self.reload()
    return name
  end

  # state of a tuya.json entry, for the web page
  def state_of(c)
    if c.find("enabled", true) == false  return "disabled"  end
    if !self.running  return "stopped"  end
    var id = str(c.find("id", ""))
    for d: self.devices
      if d.id == id  return (d.state == d.ST_READY) ? "connected" : "disconnected"  end
    end
    return "ignored"
  end

  ###################### discovery and import ######################
  # TuyaScan [s]: discovery on the local network, result published at the end
  def start_scan(sec)
    if self.scan != nil  raise "tuya_error", "discovery already running"  end
    self.check_heap(self.SCAN_MIN_HEAP)
    if sec > 60  sec = 60  end
    self.scan = TuyaScan(sec * 1000)
    return f"discovery started for {sec} s"
  end

  def scan_done()
    self.scan_result = self.scan.result()
    self.scan.close()
    self.scan = nil
    self.report("TuyaScan", {"Devices": self.scan_result})
  end

  def scan_map()
    var m = {}
    if self.scan_result != nil
      for r: self.scan_result  m[r["id"]] = r  end
    end
    return m
  end

  # TuyaImport [file] [all|id,id...]
  def import_args(p)
    import string
    var fname = nil
    var filter = nil
    for t: string.split(self.trim(str(p != nil ? p : "")), " ")
      if t == ""  continue  end
      if t[0] == "/"
        fname = t
      else
        filter = t
      end
    end
    return self.import_file(fname, filter)
  end

  # import of tinytuya's devices.json. By default: the devices found by the discovery or
  # already configured; "all": all of them; "id,id": those
  def import_file(fname, filter)
    import string
    if fname == nil || fname == ""  fname = "/devices.json"  end
    self.check_heap(self.IMPORT_MIN_HEAP)
    var conf = self.read_conf()
    var known = {}
    for c: conf["devices"]  known[str(c.find("id"))] = true  end
    var scan = self.scan_map()
    var all = (filter == "all")
    var ids = nil
    if filter != nil && !all
      ids = {}
      for x: string.split(filter, ",")  ids[self.trim(x)] = true  end
    end
    var entries = []
    var skipped = []
    try
      TuyaImport.each_object(fname, def (d)
        var id = str(d.find("id", ""))
        var keep = all || (ids != nil && ids.contains(id)) || (ids == nil && (scan.contains(id) || known.contains(id)))
        if !keep && d.find("sub") == true && ids == nil
          var par = str(d.find("parent", ""))
          keep = scan.contains(par) || known.contains(par)
        end
        if !keep  return  end
        var e = TuyaImport.entry(d, scan)
        if e == nil
          skipped.push(str(d.find("name", id)))
        else
          entries.push(e)
        end
      end)
    except "io_error" as e, m
      raise "tuya_error", f"{fname} not found"
    end
    return self.merge_entries(conf, entries, skipped)
  end

  def merge_entries(conf, entries, skipped)
    var r = TuyaImport.merge(conf, entries)
    for x: skipped  r["Skipped"].push(x)  end
    if size(r["Added"]) + size(r["Updated"]) > 0
      self.write_conf(conf)
      self.reload()
    end
    return r
  end

  # TuyaCloud {"region":"eu","id":"<Access ID>","secret":"<Access Secret>"[,"devices":["id",...]][,"save":true|false]}
  # TuyaCloud without argument: saved credentials
  def cloud_json(p)
    import json
    var a = (self.trim(str(p)) == "") ? {} : json.load(str(p))
    if type(a) != 'instance' || classname(a) != 'map'
      raise "tuya_error", "syntax: TuyaCloud {\"region\":\"eu\",\"id\":\"<Access ID>\",\"secret\":\"<Access Secret>\"}"
    end
    return self.cloud_start(a)
  end

  # saved cloud credentials: {"region","id","secret"} or nil
  def cloud_saved()
    import json
    var c
    try
      var f = open(self.CLOUD_CONF, "r")
      c = json.load(f.read())
      f.close()
    except .. as e, m
    end
    if type(c) != 'instance' || classname(c) != 'map'  return nil  end
    return (str(c.find("id", "")) != "" && str(c.find("secret", "")) != "") ? c : nil
  end

  def write_cloud(s)
    var f = open(self.CLOUD_CONF, "w")
    f.write(s)
    f.close()
  end

  # a: {"region","id","secret","devices","save"}. Empty id or secret: the saved ones.
  # "save" true: saves the credentials; false: erases them (without id or secret, nothing else).
  def cloud_start(a)
    import json
    import string
    var saved = self.cloud_saved()
    var key = self.trim(str(a.find("id", "")))
    var secret = self.trim(str(a.find("secret", "")))
    var region = string.tolower(self.trim(str(a.find("region", ""))))
    if saved != nil && (key == "" || key == saved["id"])
      key = saved["id"]
      if secret == ""  secret = saved["secret"]  end
      if region == ""  region = str(saved.find("region", "eu"))  end
    end
    if region == ""  region = "eu"  end
    var save = a.find("save")
    if save == false && saved != nil  self.write_cloud("")  end
    if save == false && key == "" && secret == ""
      return (saved != nil) ? "cloud credentials erased" : "no saved credentials"
    end
    if key == "" || secret == ""  raise "tuya_error", "Access ID and Access Secret required"  end
    if TuyaCloud.HOSTS.find(region) == nil  raise "tuya_error", "unknown region (eu, we, us, ue, cn, in, sg)"  end
    if save == true
      self.write_cloud(json.dump({"region": region, "id": key, "secret": secret}))
    end
    var note = (save == true) ? " (credentials saved)" : ""
    var msg
    try
      msg = self.start_cloud(region, key, secret, a.find("devices"))
    except "tuya_error" as e, m
      raise "tuya_error", str(m) + note
    end
    return msg + note
  end

  # cloud import: by default, the devices found by the last discovery
  def start_cloud(region, key, secret, ids)
    if self.cloud != nil  raise "tuya_error", "cloud import already running"  end
    if self.scan != nil  raise "tuya_error", "discovery running: retry when it ends"  end
    if ids == nil
      ids = []
      if self.scan_result != nil
        for r: self.scan_result  ids.push(r["id"])  end
      end
    end
    if size(ids) == 0  raise "tuya_error", "no device: run a discovery first (TuyaScan)"  end
    self.check_heap(self.CLOUD_MIN_HEAP)
    self.cloud = TuyaCloud(region, key, secret, ids)
    self.cloud_t = 0
    return f"cloud import started for {size(ids)} device(s)"
  end

  # one cloud request per second (each one blocks during the TLS handshake)
  def cloud_step()
    var more
    try
      self.check_heap(self.CLOUD_MIN_HEAP)
      more = self.cloud.next()
    except .. as e, m
      self.cloud = nil
      self.report("TuyaCloud", {"Error": str(m)})
      return
    end
    if more  return  end
    var items = self.cloud.out
    self.cloud = nil
    var r
    try
      var conf = self.read_conf()
      var scan = self.scan_map()
      var entries = []
      var skipped = []
      for d: items
        var e = TuyaImport.entry(d, scan)
        if e == nil || e.contains("cid")
          skipped.push(str(d.find("name", d.find("id"))))
        else
          entries.push(e)
        end
      end
      r = self.merge_entries(conf, entries, skipped)
    except .. as e, m
      r = {"Error": str(m)}
    end
    self.report("TuyaCloud", r)
  end

  ###################### Matter endpoints ######################
  # Matter endpoints by name: {lower-case name: endpoint number (string)}; nil if Matter is not
  # enabled
  def matter_names()
    import global
    import string
    if !global.contains("matter_device")  return nil  end
    var md = global.matter_device
    if md == nil || md.plugins_config == nil  return nil  end
    var names = {}
    for k: md.plugins_config.keys()
      var c = md.plugins_config[k]
      var n = (type(c) == 'instance') ? c.find("name") : nil
      if n != nil  names[string.tolower(str(n))] = str(k)  end
    end
    return names
  end

  # each binding (one per endpoint name) with its Matter endpoint number, nil if missing:
  # [[TuyaBinding, "6" or nil], ...]; nil if Matter is not enabled
  def matter_status()
    import string
    var names = self.matter_names()
    if names == nil  return nil  end
    var seen = {}
    var rows = []
    for d: self.devices
      for n: d.nodes()
        for b: n.bindings
          var k = string.tolower(b.ep)
          if seen.contains(k)  continue  end
          seen[k] = true
          rows.push([b, names.find(k)])
        end
      end
    end
    return rows
  end

  # bindings disabled in tuya.json ("enabled": false) of the enabled devices and sub-devices,
  # read entry by entry: [[endpoint name, type], ...]
  def matter_disabled()
    var l = []
    var scan = def (e)
      for m: e.find("matter", [])
        if m.find("enabled", true) == false  l.push([str(m.find("ep", e.find("name", ""))), m.find("type", "relay")])  end
      end
    end
    self.each_device(def (d)
      if d.find("enabled", true) == false  return  end
      scan(d)
      for ch: d.find("children", [])
        if ch.find("enabled", true) != false  scan(ch)  end
      end
    end)
    return l
  end

  # bindings without a Matter endpoint of the same name; nil if Matter is not enabled
  def matter_missing()
    var rows = self.matter_status()
    if rows == nil  return nil  end
    var miss = []
    for r: rows
      if r[1] == nil  miss.push(r[0])  end
    end
    return miss
  end

  # creates the missing virtual Matter endpoints, all of them or only those named in `only`
  # (list of names, case-insensitive) -> created names (then Restart 1 for Google Home)
  def matter_create(only)
    import global
    import string
    if !self.running  raise "tuya_error", "Tuya Local is not running: " + self.state()  end
    var miss = self.matter_missing()
    if miss == nil  raise "tuya_error", "Matter is not enabled"  end
    var want = nil
    if only != nil
      want = {}
      for n: only  want[string.tolower(self.trim(str(n)))] = true  end
    end
    var added = []
    for b: miss
      if want != nil && !want.contains(string.tolower(b.ep))  continue  end
      var t = TuyaImport.MATTER_TYPES.find(b.type)
      if t == nil  continue  end
      if global.matter_device.bridge_add_endpoint(t, {"name": b.ep}) != nil  added.push(b.ep)  end
    end
    return added
  end

  # TuyaMatter [name,name...]: all the missing endpoints, or only those
  def matter_cmd(p)
    import string
    var s = self.trim(str(p != nil ? p : ""))
    var added = self.matter_create(s == "" ? nil : string.split(s, ","))
    return {"Added": added, "Restart": size(added) > 0 ? "Restart 1 so that Google Home sees them" : ""}
  end

  def load_config()
    import string
    import json
    for d: self.devices  d.close("reload")  end
    self.devices = []
    self.by_ep = {}
    tasmota.gc()
    try
      TuyaImport.each_object(self.CONFIG, def (c)       # one entry at a time
        if c.find("enabled", true) == false  return  end
        if c.find("ip", "") == "" || !c.contains("key") || !c.contains("id")
          tasmota.log(f"TUY: incomplete device ignored: {c.find('name')}", 1)
          return
        end
        var d = TuyaDevice(c)
        self.devices.push(d)
        for n: d.nodes()
          for b: n.bindings
            self.by_ep[string.tolower(b.ep)] = b
          end
        end
      end, 1)
    except .. as e, m
      tasmota.log(f"TUY: cannot read {self.CONFIG}: {m}", 1)
      return
    end
    tasmota.log(f"TUY: {size(self.devices)} device(s), {size(self.by_ep)} Matter endpoint(s)", 2)
  end

  def every_50ms()
    for d: self.devices
      try
        d.loop()
      except .. as e, m
        tasmota.log(f"TUY: {d.name} error: {e} {m}", 2)
        d.close("internal error")
      end
    end
    var now = tasmota.millis()
    if self.scan != nil
      var running = false
      try
        running = self.scan.loop()
      except .. as e, m
        tasmota.log(f"TUY: discovery: {e} {m}", 2)
      end
      if !running  self.scan_done()  end
    end
    if self.cloud != nil && now >= self.cloud_t
      self.cloud_t = now + 1000
      self.cloud_step()
    end
    if now - self.t_sync >= self.SYNC_RETRY
      self.t_sync = now
      try
        self.sync_pending()
      except .. as e, m
        tasmota.log(f"TUY: resend to Matter: {e} {m}", 2)
      end
    end
  end

  # resends the full state to the Matter endpoints that refused an MtrUpdate: an endpoint created
  # while the driver runs thus gets the device's state without a restart
  def sync_pending()
    for d: self.devices
      for n: d.nodes()
        for b: n.bindings
          if b.pending  b.push(n.dps)  end
        end
      end
    end
  end

  # MtrReceived event: {"ep9":{"Ep":9,"Name":"Lumiere","Power":1}}
  def on_matter(v)
    import string
    import json
    if type(v) != 'instance'  return  end
    for k: v.keys()
      var a = v[k]
      if type(a) != 'instance'  continue  end
      var name = a.find("Name")
      if name == nil  continue  end
      var b = self.by_ep.find(string.tolower(name))
      if b == nil  continue  end
      var dps = b.to_tuya(a)
      if size(dps) > 0
        tasmota.log(f"TUY: Matter '{name}' -> {b.node.name} {json.dump(dps)}", 3)
        b.node.conn.set_dps(b.node, dps)
      end
    end
  end

  def find_node(name)
    import string
    name = string.tolower(name)
    for d: self.devices
      for n: d.nodes()
        if string.tolower(n.name) == name || n.id == name  return n  end
      end
    end
    return nil
  end

  # DP of a code (switch_led...) for a node, from the "codes" of its tuya.json entry (or of its
  # entry among its gateway's children), read entry by entry: codes are not kept in RAM
  def code_dp(n, code)
    var r = []
    self.each_device(def (c)
      if size(r) > 0  return  end
      var hit = (str(c.find("id")) == str(n.id)) ? c : nil
      if hit == nil
        for ch: c.find("children", [])
          if str(ch.find("id")) == str(n.id) || (n.cid != nil && str(ch.find("cid")) == str(n.cid))  hit = ch  end
        end
      end
      if hit != nil && type(hit.find("codes")) == 'instance'
        var v = hit["codes"].find(code)
        if v != nil  r.push(v)  end
      end
    end)
    return size(r) > 0 ? r[0] : nil
  end

  # TuyaSend <device>,<dp or code>,<JSON value | toggle>   e.g. TuyaSend Ventilateur,60,true
  def cmd_send(payload)
    import string
    import json
    var a = string.split(payload, ",", 2)
    if size(a) < 3  return tasmota.resp_cmnd_str("Syntax: TuyaSend <device>,<dp or code>,<value|toggle>")  end
    var n = self.find_node(self.trim(a[0]))
    if n == nil  return tasmota.resp_cmnd_str("Unknown device")  end
    var v = json.load(a[2])
    if v == nil  v = a[2]  end
    var dp = self.trim(a[1])
    var num = int(dp)
    if str(num) != dp                         # DP code (switch_led...): "codes" from the import
      var c = self.code_dp(n, dp)
      if c == nil  return tasmota.resp_cmnd_str("Unknown DP: " + dp)  end
      num = int(c)
    end
    if string.tolower(self.trim(a[2])) == "toggle"   # inverts a boolean DP (Zigbee button...)
      var cur = n.dps.find(str(num))
      if type(cur) != 'bool'
        return tasmota.resp_cmnd_str(cur == nil ? "toggle: DP state unknown" : "toggle: DP not boolean")
      end
      v = !cur
    end
    var dps = {}
    dps[str(num)] = v
    if n.conn.set_dps(n, dps)
      tasmota.resp_cmnd_done()
    else
      tasmota.resp_cmnd_str("Device not connected")
    end
  end

  def trim(s)
    var i = 0
    var j = size(s) - 1
    while i <= j && s[i] == ' '  i += 1  end
    while j >= i && s[j] == ' '  j -= 1  end
    return i <= j ? s[i .. j] : ""
  end

  def cmd_status(payload)
    import json
    import string
    var f = string.tolower(self.trim(str(payload != nil ? payload : "")))
    var r = {}
    for d: self.devices
      for n: d.nodes()
        if f != "" && string.tolower(n.name) != f && n.id != f  continue  end
        r[n.name] = {"Connected": d.state == d.ST_READY, "Ip": d.ip, "Version": d.ver, "Dps": n.all_dps()}
      end
    end
    if f != "" && size(r) == 0  return tasmota.resp_cmnd_str("Unknown device")  end
    tasmota.resp_cmnd(json.dump({"TuyaStatus": r}))
  end

  def cmd_reload()
    if !self.running  return tasmota.resp_cmnd_str("Tuya Local is not running: " + self.state())  end
    self.load_config()
    tasmota.resp_cmnd_done()
  end

  # measurements (sensors) in the SENSOR telemetry
  def json_append()
    import json
    var parts = []
    for d: self.devices
      for n: d.nodes()
        if size(n.sensors) == 0  continue  end
        var m = []
        for l: n.sensors.keys()
          var s = n.sensors[l]
          var v = n.dps.find(str(s[0]))
          if v != nil
            m.push(json.dump(l) + ":" + (type(v) == 'int' ? self.scaled(v, size(s) > 1 ? s[1] : 1) : json.dump(v)))
          end
        end
        if size(m) > 0  parts.push(json.dump(n.name) + ":{" + m.concat(",") + "}")  end
      end
    end
    if size(parts) > 0
      tasmota.response_append(',"Tuya":{' + parts.concat(",") + '}')
    end
  end

  # Tuya integer / divider (power of 10) as an exact decimal: 2268703 / 100 -> "22687.03"
  # (no float: Berry computes in single precision on the ESP32)
  def scaled(v, div)
    import string
    if div == nil || div <= 1  return str(v)  end
    var dec = 0
    var d = div
    while d > 1 && d % 10 == 0  d /= 10  dec += 1  end
    if d != 1  return string.format("%.3f", real(v) / div)  end
    var neg = v < 0
    if neg  v = -v  end
    var r = str(v / div) + "." + string.format("%0" + str(dec) + "d", v % div)
    return neg ? "-" + r : r
  end

  def web_sensor()
    var msg = ""
    for d: self.devices
      for n: d.nodes()
        if size(n.sensors) == 0  continue  end
        for l: n.sensors.keys()
          var s = n.sensors[l]
          var v = n.dps.find(str(s[0]))
          if v == nil  continue  end
          var unit = size(s) > 2 ? s[2] : ""
          var txt = type(v) == 'int' ? self.scaled(v, size(s) > 1 ? s[1] : 1) : str(v)
          msg += f"{{s}}{n.name} {l}{{m}}{txt} {unit}{{e}}"
        end
      end
    end
    if size(msg) > 0  tasmota.web_send_decimal(msg)  end
    TuyaWeb.main_button(self)
  end
end

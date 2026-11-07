#- tuya_local.be : pilotage local des appareils Tuya Wi-Fi depuis Tasmota (equivalent de LocalTuya)

  - Protocoles locaux Tuya 3.3, 3.4 et 3.5 (TCP 6668), sans le cloud
  - Sous-appareils Zigbee d'une passerelle Tuya (champ "cid")
  - Pont vers Matter : endpoints virtuels (v_relay, v_light2, v_fan...) pilotes par
    l'evenement MtrReceived et mis a jour par la commande MtrUpdate
  - Valeurs de mesure (pince amperemetrique...) dans les releves Tasmota et la page web

  Configuration : fichier /tuya.json (voir tuya.example.json et docs/tuya-local.fr.md), ou
  page web Configuration -> Tuya local (/tuya)
  Commandes : TuyaStatus [appareil], TuyaSend <appareil>,<dp ou code>,<valeur|toggle>, TuyaReload,
    TuyaConfig [appareil], TuyaAdd <json>, TuyaDel <appareil>, TuyaScan [s],
    TuyaImport [fichier] [all|id,...], TuyaCloud <json>, TuyaMatter

  Necessite un firmware avec USE_BERRY_CRYPTO_AES_CBC (3.3, 3.4) et le correctif
  AES_GCM 128 bits avec AAD (3.5).

  Solidifie dans le firmware (custom_berry_solidify) : les classes sont alors en flash, en
  lecture seule, et deviennent des classes natives. D'ou trois regles :
  - pas de code au premier niveau hors des classes : le driver est instancie par autoexec.be
    (`global.tuya_local = TuyaLocal()`), pas par ce fichier ;
  - les modules (string, json, crypto) sont importes dans les methodes qui s'en servent ;
  - pas d'ecriture dans une variable statique (`static var`) : constantes uniquement.
  Le fichier reste chargeable tel quel avec load("tuya_local.be") sur un firmware qui ne
  l'embarque pas (meme instanciation ensuite).
-#

#################################################################################
# TuyaCodec : primitives du protocole (sans etat)
#################################################################################
#@ solidify:TuyaCodec,weak
class TuyaCodec
  # CRC-32 (polynome 0xEDB88320) par quartet : table constante de 16 entrees, sans calcul
  # au premier appel (une classe solidifiee est en lecture seule)
  static var CRC_NIBBLE = [0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC, 0x76DC4190, 0x6B6B51F4,
                           0x4DB26158, 0x5005713C, 0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C,
                           0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C]
  # commandes envoyees sans l'en-tete de version "3.x" + 12 octets nuls
  static var NO_HEADER = [3, 4, 5, 9, 10, 16, 18, 64]
  # cle des annonces UDP (decouverte) : md5("yGAdlopoPVldABfn"), comme tinytuya
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

  # AES-128-ECB, bloc par bloc, avec AES-CBC et un IV nul
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

  # trame 6699 (3.5) : AES-128-GCM, en-tete (octets 4 a 17) en donnees authentifiees
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

  # annonce UDP d'un appareil (ports 6666, 6667, 7000) -> map JSON, ou nil
  # 55AA : en clair (3.1) ou AES-ECB avec UDP_KEY (3.3) ; 6699 : AES-GCM avec UDP_KEY (3.5)
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
      p = pkt[20 .. total - 9]                        # apres le code retour, avant CRC + suffixe
      if size(p) > 0 && p[0] != 0x7B                  # pas '{' : chiffre
        if size(p) % 16 != 0  return nil  end
        p = TuyaCodec.unpad(TuyaCodec.ecb(k, p, false))
      end
    elif pfx == 0x00006699
      var total = 18 + pkt.get(14, -4) + 4
      if total > n || total < 50  return nil  end
      var g = crypto.AES_GCM(k, pkt[18 .. 29], pkt[4 .. 17])
      p = g.decrypt(pkt[30 .. total - 21])
      if g.tag() != pkt[total - 20 .. total - 5]  return nil  end
      if size(p) > 4 && p[0] != 0x7B && p[4] == 0x7B  p = p[4 ..]  end   # code retour
    else
      return nil
    end
    var sz = size(p)
    while sz > 0 && p[sz - 1] == 0  sz -= 1  end     # octets nuls de fin (appli)
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
# TuyaBinding : liaison entre des DP Tuya et un endpoint Matter virtuel
#################################################################################
#@ solidify:TuyaBinding,weak
class TuyaBinding
  var node            # TuyaNode (appareil ou sous-appareil) qui porte les DP
  var ep              # nom de l'endpoint Matter
  var type            # relay, relay_power, light0..3, fan, temp, humidity
  var c               # configuration (map)
  var pending         # true : le dernier MtrUpdate a ete refuse (endpoint absent), a renvoyer

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

  # Matter -> Tuya : attributs MtrReceived -> map de DP a envoyer
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
        var cmin = self.num("ct_min", 153)       # mireds de la valeur Tuya 1000 (froid)
        var cmax = self.num("ct_max", 500)       # mireds de la valeur Tuya 0 (chaud)
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

  # couleur Tuya (colour_data_v2) : "hhhhssssvvvv", h 0..360, s et v 0..1000
  def hsv_get()
    var s = self.node.dps.find(self.dp("dp_colour", 24))
    if type(s) == 'string' && size(s) == 12
      return [int("0x" + s[0..3]), int("0x" + s[4..7]), int("0x" + s[8..11])]
    end
    return [0, 1000, 1000]
  end

  # Tuya -> Matter : envoie a l'endpoint les attributs touches par `changed` (map de DP).
  # Si l'endpoint refuse (absent, cree apres le driver...), la liaison passe en attente et
  # TuyaLocal lui renvoie l'etat complet toutes les SYNC_RETRY ms. Renvoie false si refuse.
  def push(changed)
    import json
    var r = self.to_matter(changed)
    if r == nil  return true  end
    r["Name"] = self.ep
    var res = tasmota.cmd("MtrUpdate " + json.dump(r), true)
    var v = (type(res) == 'instance') ? res.find("MtrUpdate") : nil
    # accepte : l'etat de l'endpoint, ou "Done" pour un endpoint qui n'en publie pas (v_fan)
    if type(v) == 'instance' || v == "Done"
      if self.pending
        tasmota.log(f"TUY: endpoint Matter '{self.ep}' disponible, etat envoye", 2)
        self.pending = false
      end
      return true
    end
    if !self.pending                  # "Invalid Device", "Invalid attribute '...'" ou rien : signale une fois
      var why = (v != nil) ? v : res
      tasmota.log(f"TUY: endpoint Matter '{self.ep}' : {why} (nouvel essai toutes les 30 s)", 2)
      self.pending = true
    end
    return false
  end

  # Tuya -> Matter : etat courant -> attributs MtrUpdate (nil si rien ne concerne cet endpoint)
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
# TuyaNode : un appareil logique (appareil Wi-Fi ou sous-appareil de passerelle)
#################################################################################
#@ solidify:TuyaNode,weak
class TuyaNode
  var name, id, cid          # cid : identifiant du sous-appareil (nil pour un appareil Wi-Fi)
  var conn                   # TuyaDevice qui porte la connexion TCP
  var dps                    # dernier etat connu {"1": true, ...}
  var bindings               # list de TuyaBinding
  var sensors                # {"label": [dp, diviseur, unite]} : releves Tasmota
  var seen                   # millis de la derniere reception
  var codes                  # {"switch_led": 20, ...} (import) : TuyaSend par code, ou nil

  def init(conn, conf)
    self.conn = conn
    self.name = conf.find("name", conf.find("id"))
    self.id = conf.find("id")
    self.cid = conf.find("cid")
    self.dps = {}
    self.bindings = []
    self.sensors = conf.find("sensors", {})
    self.codes = conf.find("codes")
    for m: conf.find("matter", [])
      self.bindings.push(TuyaBinding(self, m))
    end
  end

  # nouvelles valeurs recues de l'appareil
  def update(dps)
    import json
    var changed = {}
    for k: dps.keys()
      var ks = str(k)
      if self.dps.find(ks) != dps[k] || !self.dps.contains(ks)
        changed[ks] = dps[k]
      end
      self.dps[ks] = dps[k]
    end
    self.seen = tasmota.millis()
    if size(changed) == 0  return  end
    tasmota.log(f"TUY: {self.name} {json.dump(changed)}", 3)
    tasmota.publish_result(json.dump({"Tuya": {"Name": self.name, "Dps": changed}}), "RESULT")
    for b: self.bindings
      if b.pending
        b.push(self.dps)                # endpoint en attente : etat complet
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
# TuyaDevice : connexion TCP vers un appareil Wi-Fi (ou une passerelle) et protocole
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

  ###################### connexion ######################
  def close(reason)
    if self.tcp  self.tcp.close()  end
    self.tcp = nil
    if self.state != self.ST_IDLE
      tasmota.log(f"TUY: {self.name} ({self.ip}) deconnecte : {reason}", 2)
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
    tasmota.log(f"TUY: {self.name} ({self.ip}) connecte, protocole {self.ver}", 2)
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
        self.close("connexion impossible")
        return
      end
      return
    end
    if c != true
      self.close("connexion fermee")
      return
    end
    # reception
    if self.tcp.available() > 0
      self.rx .. self.tcp.readbytes()
      self.t_last_rx = now
      self.parse()
      if self.tcp == nil  return  end
    end
    # emission en attente
    self.flush()
    if self.state == self.ST_NEGO && now - self.t_state > 5000
      self.close("negociation de cle sans reponse")
      return
    end
    if self.state == self.ST_READY
      if now - self.t_last_rx > 35000
        self.close("plus de reponse")
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

  ###################### emission ######################
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

  # envoi de DP vers un appareil ou un sous-appareil (node)
  def set_dps(node, dps)
    import json
    if self.state != self.ST_READY
      tasmota.log(f"TUY: {node.name} non connecte, commande ignoree", 2)
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
        # resynchronisation : on cherche le prochain prefixe
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
        self.close("trame invalide")
        return
      end
      if n < total  return  end
      var frame = self.rx[0 .. total - 1]
      self.rx = (n > total) ? self.rx[total ..] : bytes()
      try
        self.handle(frame)
      except .. as e, m
        tasmota.log(f"TUY: {self.name} erreur de decodage : {e} {m}", 2)
      end
      if self.tcp == nil  return  end
    end
  end

  # decode une trame complete -> (cmd, payload en clair sans code retour)
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
      if g.tag() != tag  raise "tag_error", "authentification GCM invalide"  end
      return [cmd, size(pt) >= 4 ? pt[4 ..] : bytes()]
    end
    var cmd = frame.get(8, -4)
    var use_hmac = self.v34()
    var end_len = use_hmac ? 36 : 8
    var signed = frame[0 .. total - end_len - 1]
    if use_hmac
      if TuyaCodec.hmac(k, signed) != frame[total - 36 .. total - 5]  raise "hmac_error", "HMAC invalide"  end
    else
      if TuyaCodec.crc32(signed, size(signed)) != frame.get(total - 8, -4)  raise "crc_error", "CRC invalide"  end
    end
    var body = (total - end_len > 20) ? frame[20 .. total - end_len - 1] : bytes()     # apres le code retour
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
      tasmota.log(f"TUY: {self.name} JSON invalide : {s}", 3)
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
        tasmota.log(f"TUY: {self.name} sous-appareil inconnu cid={cid}", 3)
        return
      end
    end
    node.update(dps)
  end

  ###################### negociation de cle (3.4 / 3.5) ######################
  def nego_step2(p)
    import crypto
    if self.state != self.ST_NEGO || size(p) < 48
      self.close("negociation : reponse inattendue")
      return
    end
    var remote = p[0 .. 15]
    if TuyaCodec.hmac(self.key, self.nonce) != p[16 .. 47]
      self.close("negociation : cle locale incorrecte ?")
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
# TuyaScan : decouverte des appareils Wi-Fi sur le reseau local (comme tinytuya scan)
# Instanciee a la demande (TuyaScan), liberee a la fin : rien en RAM le reste du temps.
#################################################################################
#@ solidify:TuyaScan,weak
class TuyaScan
  static var PORTS = [6666, 6667, 7000]     # 3.1 en clair, 3.3 chiffre, 3.5 (appli)
  static var REQUEST_EVERY = 6000           # ms entre deux demandes aux appareils 3.5
  var socks                   # list de udp
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
        tasmota.log(f"TUY: recherche : port UDP {p} indisponible", 2)
      end
    end
    self.t_end = tasmota.millis() + ms
    self.t_req = 0
    var e = tasmota.eth()                     # Ethernet, sinon Wi-Fi
    self.ip = (e != nil) ? e.find("ip", "") : ""
    if self.ip == "" || self.ip == "0.0.0.0"
      var w = tasmota.wifi()
      self.ip = (w != nil) ? w.find("ip", "") : ""
    end
  end

  # appelee toutes les 50 ms ; false quand la recherche est finie
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

  # les appareils 3.5 ne s'annoncent qu'a la demande : trame 6699 REQ_DEVINFO (0x25) diffusee
  # sur le port 7000, comme l'appli Tuya et tinytuya scan
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
    if m == nil || m.contains("from")  return  end     # notre propre demande
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
# TuyaImport : appareils de tinytuya (devices.json) ou du cloud -> entrees de tuya.json
# Fonctions statiques uniquement.
#################################################################################
#@ solidify:TuyaImport,weak
class TuyaImport
  # type du driver -> type d'endpoint Matter virtuel
  static var MATTER_TYPES = {"relay": "v_relay", "relay_power": "v_relay_power", "light0": "v_light0",
                             "light1": "v_light1", "light2": "v_light2", "light3": "v_light3",
                             "fan": "v_fan", "temp": "v_temp", "humidity": "v_humidity"}
  static var MAX_OBJECT = 8192      # octets : au-dela, l'objet JSON est ignore (RAM)

  # appelle cb(objet) pour chaque objet d'un tableau JSON, lu par morceaux de 512 octets :
  # le devices.json de tinytuya (avec les mappings) peut depasser la RAM libre
  static def each_object(fname, cb)
    import json
    var f = open(fname, "r")
    var depth = 0
    var in_str = false
    var esc = false
    var acc = nil                 # bytes de l'objet en cours, nil hors objet
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
            if depth == 0  acc = bytes()  start = i  skip = false  end
            depth += 1
          elif c == 0x7D
            depth -= 1
            if depth == 0
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
            tasmota.log("TUY: import : objet JSON trop gros, ignore", 2)
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

  # diviseur d'un DP entier : 10^scale (et mA -> A pour le courant)
  static def div(mapping, dp, ma)
    var v = TuyaImport.values(mapping, dp)
    var d = 1
    var s = int(v.find("scale", 0))
    while s > 0  d *= 10  s -= 1  end
    if ma && v.find("unit") == "mA"  d *= 1000  end
    return d
  end

  # nom d'endpoint Matter : 32 octets au plus, sans couper un caractere UTF-8
  static def ep_name(s)
    var b = bytes().fromstring(s)
    if size(b) <= 32  return s  end
    var n = 32
    while n > 0 && (b[n] & 0xC0) == 0x80  n -= 1  end
    return b[0 .. n - 1].asstring()
  end

  # liaisons Matter et releves deduits de la categorie Tuya et des codes de DP
  # -> [matter (list), sensors (map)]
  static def auto(name, category, mapping)
    var c = TuyaImport.codes(mapping)
    var matter = []
    var sensors = {}
    var cat = str(category)
    var fan_cat = (cat == "fs" || cat == "fsd" || cat == "fskg")
    var speed = c.find("fan_speed", c.find("fan_speed_percent"))
    if fan_cat || speed != nil
      # ventilateur : marche/arret + vitesse entiere ; vitesse en enumeration : marche/arret seul
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
      # lumiere : couleur (v2) > temperature de couleur (v2) > variateur > marche/arret
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
    # interrupteurs et prises : switch, switch_1 ... switch_8 ; prise avec mesures : relay_power
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
    # capteurs de temperature et d'humidite
    var tc = c.find("va_temperature", c.find("temp_current"))
    var hc = c.find("va_humidity", c.find("humidity_value"))
    if size(matter) == 0 && tc != nil
      matter.push({"ep": TuyaImport.ep_name(name), "type": "temp", "dp": tc, "div": TuyaImport.div(mapping, tc, false)})
    end
    if size(matter) <= 1 && hc != nil
      matter.push({"ep": TuyaImport.ep_name(name + " humidité"), "type": "humidity", "dp": hc, "div": TuyaImport.div(mapping, hc, false)})
    end
    # compteurs d'energie : toutes les mesures entieres avec une unite
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

  # appareil tinytuya ou cloud -> entree de tuya.json (nil sans cle locale)
  # scan : {"id": resultat de TuyaScan} pour l'IP et la version
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
    var e = {"name": name, "id": id, "key": key, "ip": ip, "version": ver}   # "" : inconnues
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
      e["enabled"] = false                    # IP inconnue : a completer (recherche)
    end
    return e
  end

  # fusionne les entrees dans conf ; un appareil deja configure (meme id) garde ses liaisons,
  # seuls sa cle, son IP et sa version sont mis a jour -> {"Added": [], "Updated": [], "Skipped": []}
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
    # sous-appareils : rattaches a leur passerelle si elle est configuree
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

  # index d'un appareil par id ou par nom (sans casse), ou nil
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
# TuyaCloud : cles locales et DP depuis le cloud Tuya (API OpenAPI, comme tinytuya wizard)
# Une requete HTTPS par etape, instanciee a la demande. Les identifiants ne sont pas stockes.
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
    if self.host == nil  raise "tuya_error", "region inconnue (eu, we, us, ue, cn, in, sg)"  end
    if key == nil || key == "" || secret == nil || secret == ""  raise "tuya_error", "Access ID et Access Secret requis"  end
    self.key = key
    self.secret = secret
    self.ids = ids
    self.i = 0
    self.step = 0
    self.out = []
  end

  # signature Tuya OpenAPI (nouvel algorithme), requete GET sans corps ni en-tete signe :
  # HMAC-SHA256(secret, client_id + [access_token] + t + "GET\n" + sha256("") + "\n\n" + chemin)
  static def sign(key, secret, token, t, path)
    import crypto
    import string
    var s = key + (token != nil ? token : "") + t + "GET\n" + TuyaCloud.EMPTY_SHA256 + "\n\n" + path
    return string.toupper(crypto.HMAC_SHA256(bytes().fromstring(secret)).update(bytes().fromstring(s)).out().tohex())
  end

  static def now_ms()
    var u = tasmota.rtc()["utc"]
    if u < 1600000000  raise "tuya_error", "heure non synchronisee (NTP)"  end
    return str(u) + "000"
  end

  # entiers de plus de 9 chiffres -> chaines. Toute reponse du cloud porte l'heure en ms
  # ("t":1794092132086), qui depasse les entiers 32 bits de Berry : json.load renverrait nil.
  # Seules les valeurs d'une cle ("cle":123...) sont touchees, pas le JSON echappe des "values".
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
      wc.add_header("secret", self.secret)    # comme tinytuya pour la demande de jeton
    end
    var code = wc.GET()
    var s = (code == 200) ? wc.get_string() : nil
    wc.close()
    if s == nil  raise "tuya_error", f"cloud Tuya : HTTP {code}"  end
    var m = json.load(TuyaCloud.quote_big(s))
    s = nil
    if m == nil || m.find("success") != true
      var why = (m != nil) ? m.find("msg", m.find("code")) : "reponse invalide"
      raise "tuya_error", f"cloud Tuya : {why}"
    end
    return m["result"]
  end

  # "status" et "functions" des specifications -> mapping au format tinytuya
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

  # une requete par appel : jeton, puis pour chaque appareil details (cle) et specifications (DP)
  # -> true tant qu'il reste des requetes
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
        tasmota.log(f"TUY: cloud : pas de DP pour {id} : {m}", 2)
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
# TuyaWeb : page Configuration -> Tuya local (/tuya). Fonctions statiques uniquement.
#################################################################################
#@ solidify:TuyaWeb,weak
class TuyaWeb
  static def esc(s)
    import webserver
    return webserver.html_escape(str(s))
  end

  static def button()
    import webserver
    webserver.content_send("<p></p><form id=tuya action='tuya' style='display: block;' method='get'><button>Tuya local</button></form>")
  end

  static def page(drv)
    import webserver
    if !webserver.check_privileged_access()  return nil  end
    webserver.content_start("Tuya local")
    webserver.content_send_style()
    if drv.web_msg != nil
      webserver.content_send("<p style='text-align:center'><b>" + TuyaWeb.esc(drv.web_msg) + "</b></p>")
      drv.web_msg = nil
    end
    if webserver.has_arg("edit")
      TuyaWeb.edit(drv, webserver.arg("edit"))
    else
      TuyaWeb.devices(drv)
      TuyaWeb.matter(drv)
      TuyaWeb.scan(drv)
      TuyaWeb.imports(drv)
    end
    webserver.content_button(webserver.BUTTON_CONFIGURATION)
    webserver.content_stop()
  end

  static def devices(drv)
    import webserver
    webserver.content_send("<fieldset><legend><b>&nbsp;Appareils&nbsp;</b></legend>")
    var conf
    try
      conf = drv.read_conf()
    except .. as e, m
      webserver.content_send("<p>" + TuyaWeb.esc(m) + "</p>")
    end
    if conf != nil
      webserver.content_send("<table style='width:100%'><tr><th>Nom</th><th>IP</th><th>Ver.</th><th>État</th><th></th></tr>")
      for c: conf["devices"]
        var id = str(c.find("id", ""))
        var row = "<tr><td>" + TuyaWeb.esc(c.find("name", id)) + "</td><td>" + TuyaWeb.esc(c.find("ip", "")) +
                  "</td><td>" + TuyaWeb.esc(c.find("version", "")) + "</td><td>" + drv.state_of(c) +
                  "</td><td><a href='/tuya?edit=" + TuyaWeb.esc(id) + "'>Modifier</a></td></tr>"
        webserver.content_send(row)
      end
      webserver.content_send("</table>")
    end
    webserver.content_send("<p></p><form action='/tuya' method='get'><input type='hidden' name='edit' value=''><button>Ajouter un appareil</button></form>")
    webserver.content_send("<p></p><form action='/tuya' method='post'><button name='reload'>Recharger tuya.json</button></form></fieldset><p></p>")
  end

  static def edit(drv, ref)
    import webserver
    import json
    var d = nil
    if ref != ""
      var conf = drv.read_conf()
      var i = TuyaImport.find(conf["devices"], ref)
      if i != nil  d = conf["devices"][i]  end
    end
    if d == nil
      ref = ""
      d = {"name": "", "id": "", "key": "", "ip": "", "version": "3.3", "matter": [{"ep": "", "type": "relay", "dp": 1}]}
    elif d.contains("key")
      d["key"] = "***"
    end
    var title = (ref == "") ? "Nouvel appareil" : "Appareil"
    webserver.content_send("<fieldset><legend><b>&nbsp;" + title + "&nbsp;</b></legend>")
    webserver.content_send("<p>Configuration en JSON (voir la documentation). Une clé <code>***</code> conserve la clé enregistrée.</p>")
    webserver.content_send("<form action='/tuya' method='post'><input type='hidden' name='ref' value='" + TuyaWeb.esc(ref) + "'>")
    webserver.content_send("<textarea name='json' rows='18' style='width:100%;font-family:monospace'>" + TuyaWeb.esc(json.dump(d, "format")) + "</textarea>")
    webserver.content_send("<button name='save' class='button bgrn'>Enregistrer</button></form>")
    if ref != ""
      webserver.content_send("<p></p><form action='/tuya' method='post' onsubmit='return confirm(\"Supprimer cet appareil ?\")'>" +
                             "<input type='hidden' name='ref' value='" + TuyaWeb.esc(ref) + "'><button name='del' class='button bred'>Supprimer</button></form>")
    end
    webserver.content_send("<p></p><form action='/tuya' method='get'><button>Retour</button></form></fieldset><p></p>")
  end

  static def matter(drv)
    import webserver
    webserver.content_send("<fieldset><legend><b>&nbsp;Endpoints Matter&nbsp;</b></legend>")
    var miss = drv.matter_missing()
    if miss == nil
      webserver.content_send("<p>Matter n'est pas actif.</p>")
    elif size(miss) == 0
      webserver.content_send("<p>Chaque liaison du driver a son endpoint Matter.</p>")
    else
      var l = []
      for b: miss  l.push(TuyaWeb.esc(b.ep) + " <small>(" + TuyaImport.MATTER_TYPES.find(b.type, "?") + ")</small>")  end
      webserver.content_send("<p>Sans endpoint Matter : " + l.concat(", ") + "</p>")
      webserver.content_send("<form action='/tuya' method='post' onsubmit='return confirm(\"Créer les endpoints et redémarrer ?\")'>" +
                             "<button name='matter' class='button bgrn'>Créer les endpoints et redémarrer</button></form>")
    end
    webserver.content_send("</fieldset><p></p>")
  end

  static def scan(drv)
    import webserver
    webserver.content_send("<fieldset><legend><b>&nbsp;Recherche sur le réseau&nbsp;</b></legend>")
    if drv.scan != nil
      webserver.content_send("<p>Recherche en cours...</p><script>setTimeout(function(){location.href='/tuya'},4000)</script>")
    else
      webserver.content_send("<form action='/tuya' method='post'><button name='scan'>Rechercher les appareils (20 s)</button></form>")
    end
    if drv.scan_result != nil
      var conf
      try  conf = drv.read_conf()  except .. as e, m  conf = {"devices": []}  end
      webserver.content_send("<table style='width:100%'><tr><th>Id</th><th>IP</th><th>Ver.</th><th></th></tr>")
      for r: drv.scan_result
        var known = (TuyaImport.find(conf["devices"], r["id"]) != nil) ? "configuré" : "nouveau"
        webserver.content_send("<tr><td><small>" + TuyaWeb.esc(r["id"]) + "</small></td><td>" + TuyaWeb.esc(r["ip"]) +
                               "</td><td>" + TuyaWeb.esc(r["version"]) + "</td><td>" + known + "</td></tr>")
      end
      webserver.content_send("</table>")
    end
    webserver.content_send("</fieldset><p></p>")
  end

  static def imports(drv)
    import webserver
    var heap = tasmota.memory().find("heap_free", 0)
    webserver.content_send("<fieldset><legend><b>&nbsp;Importer les clés locales&nbsp;</b></legend>")
    webserver.content_send("<p>Depuis le <code>devices.json</code> de <code>tinytuya wizard</code>, envoyé par Outils → Gestion des fichiers. " +
                           "Sans « tous », seuls les appareils trouvés par la recherche ou déjà configurés sont importés.</p>")
    webserver.content_send("<form action='/tuya' method='post'><input name='file' value='/devices.json'>" +
                           "<label><input type='checkbox' name='all'> tous</label><button name='import'>Importer</button></form>")
    webserver.content_send("<p>Ou depuis le cloud Tuya, pour les appareils trouvés par la recherche (compte Tuya IoT, comme " +
                           "<code>tinytuya wizard</code> ; identifiants non enregistrés). Mémoire libre : " + str(heap) + " Ko, " +
                           str(drv.CLOUD_MIN_HEAP) + " Ko nécessaires.</p>")
    webserver.content_send("<form action='/tuya' method='post'><select name='region'><option value='eu'>Europe centrale</option>" +
                           "<option value='we'>Europe de l'ouest</option><option value='us'>Amérique de l'ouest</option>" +
                           "<option value='ue'>Amérique de l'est</option><option value='cn'>Chine</option><option value='in'>Inde</option>" +
                           "<option value='sg'>Singapour</option></select>" +
                           "<input name='cid' placeholder='Access ID'><input name='secret' type='password' placeholder='Access Secret'>" +
                           "<button name='cloud'>Importer depuis le cloud</button></form>")
    webserver.content_send("</fieldset><p></p>")
  end

  # formulaires (POST /tuya) -> action, message pour la page suivante, redirection
  static def post(drv)
    import webserver
    import json
    if !webserver.check_privileged_access()  return nil  end
    var msg = nil
    var rst = false
    try
      if webserver.has_arg("save")
        var d = json.load(webserver.arg("json"))
        if type(d) != 'instance' || classname(d) != 'map'  raise "tuya_error", "JSON invalide"  end
        var ref = webserver.arg("ref")
        msg = "Enregistré : " + drv.save_device(d, ref != "" ? ref : nil)
      elif webserver.has_arg("del")
        msg = "Supprimé : " + drv.del_device(webserver.arg("ref"))
      elif webserver.has_arg("reload")
        drv.load_config()
        msg = "tuya.json rechargé"
      elif webserver.has_arg("scan")
        msg = drv.start_scan(20)
      elif webserver.has_arg("import")
        msg = drv.summary(drv.import_file(webserver.arg("file"), webserver.has_arg("all") ? "all" : nil))
      elif webserver.has_arg("cloud")
        msg = drv.start_cloud(webserver.arg("region"), webserver.arg("cid"), webserver.arg("secret"), nil)
      elif webserver.has_arg("matter")
        var added = drv.matter_create()
        msg = "Endpoints Matter créés : " + str(size(added)) + ", redémarrage"
        rst = size(added) > 0
      end
    except .. as e, m
      msg = "Erreur : " + str(m)
    end
    drv.web_msg = msg
    webserver.redirect(rst ? "/?rst=" : "/tuya")
  end
end

#################################################################################
# TuyaLocal : driver Tasmota
#################################################################################
#@ solidify:TuyaLocal,weak
class TuyaLocal
  static var CONFIG = "/tuya.json"
  static var SYNC_RETRY = 30000   # ms entre deux renvois aux endpoints Matter qui ont refuse
  # memoire libre minimale (Ko) pour lancer : une recherche, un import de fichier, un import cloud
  # (HTTPS : le client TLS de Tasmota reserve a lui seul 16 Ko)
  static var SCAN_MIN_HEAP = 15
  static var IMPORT_MIN_HEAP = 20
  static var CLOUD_MIN_HEAP = 35
  static var LABELS = {"Added": "ajoutés", "Updated": "mis à jour", "Skipped": "ignorés"}
  var devices                 # list de TuyaDevice
  var by_ep                   # {nom d'endpoint Matter en minuscules: TuyaBinding}
  var t_sync                  # millis du dernier renvoi
  var scan, scan_result       # recherche en cours (TuyaScan) et dernier resultat (list)
  var cloud, cloud_t          # import cloud en cours (TuyaCloud) et millis de la prochaine requete
  var web_msg                 # message a afficher sur la page web

  def init()
    self.devices = []
    self.by_ep = {}
    self.t_sync = tasmota.millis()
    self.load_config()
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
    tasmota.add_cmd("TuyaMatter", /c, i, p -> self.run_cmd("TuyaMatter", / -> self.matter_cmd()))
    # page web : le driver demarre apres le serveur web, qui n'appelle donc pas web_add_handler()
    import webserver
    if webserver.state() > 0  self.web_add_handler()  end
  end

  # page Configuration -> Tuya local
  def web_add_config_button()
    TuyaWeb.button()
  end
  def web_add_handler()
    import webserver
    webserver.on("/tuya", / -> TuyaWeb.page(self), webserver.HTTP_GET)
    webserver.on("/tuya", / -> TuyaWeb.post(self), webserver.HTTP_POST)
  end

  # commande -> reponse JSON {"<commande>": resultat} ou {"<commande>": {"Error": "..."}}
  def run_cmd(name, f)
    import json
    var r
    try
      r = f()
    except .. as e, m
      r = {"Error": str(m)}
      if e != "tuya_error"  tasmota.log(f"TUY: {name} : {e} {m}", 2)  end
    end
    var o = {}
    o[name] = r
    tasmota.resp_cmnd(json.dump(o))
  end

  # resultat d'une operation en arriere-plan : journal, MQTT (RESULT) et page web
  def report(name, r)
    import json
    var o = {}
    o[name] = r
    tasmota.log(f"TUY: {name} {json.dump(r)}", 2)
    tasmota.publish_result(json.dump(o), "RESULT")
    self.web_msg = name + " : " + self.summary(r)
  end

  def summary(r)
    if type(r) != 'instance'  return str(r)  end
    if r.contains("Error")  return "erreur : " + str(r["Error"])  end
    if r.contains("Devices")  return str(size(r["Devices"])) + " appareil(s) trouvé(s)"  end
    var l = []
    for k: ["Added", "Updated", "Skipped"]
      if r.contains(k) && size(r[k]) > 0  l.push(self.LABELS[k] + " : " + r[k].concat(", "))  end
    end
    return size(l) > 0 ? l.concat(" ; ") : "aucun appareil importé"
  end

  def check_heap(min)
    var h = tasmota.memory().find("heap_free", 0)
    if h < min  raise "tuya_error", f"memoire libre insuffisante : {h} Ko, {min} Ko necessaires"  end
  end

  ###################### fichier de configuration ######################
  # /tuya.json -> map ; absent ou vide : configuration vide ; invalide : erreur (jamais ecrase)
  def read_conf()
    import json
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
      raise "tuya_error", f"{self.CONFIG} n'est pas un JSON valide : non modifie"
    end
    if type(conf.find("devices")) != 'instance'  conf["devices"] = []  end
    return conf
  end

  # ecrit /tuya.json, l'ancienne version etant gardee dans /tuya.json.bak
  def write_conf(conf)
    import json
    try
      var fi = open(self.CONFIG, "r")
      var old = fi.read()
      fi.close()
      var fb = open(self.CONFIG + ".bak", "w")
      fb.write(old)
      fb.close()
    except .. as e, m
    end
    var fo = open(self.CONFIG, "w")
    fo.write(json.dump(conf, "format"))
    fo.close()
  end

  # TuyaConfig [appareil] : configuration sans les cles
  def masked_conf(ref)
    var conf = self.read_conf()
    for d: conf["devices"]
      if d.contains("key")  d["key"] = "***"  end
    end
    ref = self.trim(str(ref != nil ? ref : ""))
    if ref == ""  return conf  end
    var i = TuyaImport.find(conf["devices"], ref)
    if i == nil  raise "tuya_error", "appareil inconnu"  end
    return conf["devices"][i]
  end

  # TuyaAdd {"name":...,"id":...,"key":...,"ip":...,"version":...,"matter":[...]}
  def add_json(p)
    import json
    var d = json.load(str(p))
    if type(d) != 'instance' || classname(d) != 'map'
      raise "tuya_error", "syntaxe : TuyaAdd {\"name\":...,\"id\":...,\"key\":...,\"ip\":...,\"version\":...,\"matter\":[...]}"
    end
    return self.save_device(d, nil)
  end

  # ajoute ou remplace un appareil (designe par ref, sinon par son id) -> nom de l'appareil.
  # Cle absente, vide ou "***" : la cle enregistree est conservee.
  def save_device(d, ref)
    if str(d.find("name", "")) == "" || str(d.find("id", "")) == ""  raise "tuya_error", "name et id requis"  end
    var conf = self.read_conf()
    var devs = conf["devices"]
    var i = TuyaImport.find(devs, ref != nil ? ref : d["id"])
    var k = d.find("key")
    if k == nil || k == "" || k == "***"
      if i == nil || devs[i].find("key") == nil  raise "tuya_error", "cle locale (key) requise"  end
      d["key"] = devs[i]["key"]
    end
    if i == nil
      if TuyaImport.find(devs, d["name"]) != nil || TuyaImport.find(devs, d["id"]) != nil
        raise "tuya_error", "nom ou id deja utilise"
      end
      devs.push(d)
    else
      devs[i] = d
    end
    self.write_conf(conf)
    self.load_config()
    return d["name"]
  end

  # TuyaDel <appareil> -> nom de l'appareil supprime
  def del_device(ref)
    var conf = self.read_conf()
    var i = TuyaImport.find(conf["devices"], ref)
    if i == nil  raise "tuya_error", "appareil inconnu"  end
    var name = conf["devices"][i].find("name", ref)
    conf["devices"].remove(i)
    self.write_conf(conf)
    self.load_config()
    return name
  end

  # etat d'une entree de tuya.json, pour la page web
  def state_of(c)
    if c.find("enabled", true) == false  return "désactivé"  end
    var id = str(c.find("id", ""))
    for d: self.devices
      if d.id == id  return (d.state == d.ST_READY) ? "connecté" : "déconnecté"  end
    end
    return "ignoré"
  end

  ###################### recherche et import ######################
  # TuyaScan [s] : recherche sur le reseau local, resultat publie a la fin
  def start_scan(sec)
    if self.scan != nil  raise "tuya_error", "recherche deja en cours"  end
    self.check_heap(self.SCAN_MIN_HEAP)
    if sec > 60  sec = 60  end
    self.scan = TuyaScan(sec * 1000)
    return f"recherche lancee pour {sec} s"
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

  # TuyaImport [fichier] [all|id,id...]
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

  # import du devices.json de tinytuya. Par defaut : les appareils trouves par la recherche ou
  # deja configures ; "all" : tous ; "id,id" : ceux-la
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
      raise "tuya_error", f"{fname} introuvable"
    end
    return self.merge_entries(conf, entries, skipped)
  end

  def merge_entries(conf, entries, skipped)
    var r = TuyaImport.merge(conf, entries)
    for x: skipped  r["Skipped"].push(x)  end
    if size(r["Added"]) + size(r["Updated"]) > 0
      self.write_conf(conf)
      self.load_config()
    end
    return r
  end

  # TuyaCloud {"region":"eu","id":"<Access ID>","secret":"<Access Secret>"[,"devices":["id",...]]}
  def cloud_json(p)
    import json
    var a = json.load(str(p))
    if type(a) != 'instance' || classname(a) != 'map'
      raise "tuya_error", "syntaxe : TuyaCloud {\"region\":\"eu\",\"id\":\"<Access ID>\",\"secret\":\"<Access Secret>\"}"
    end
    return self.start_cloud(a.find("region", "eu"), a.find("id"), a.find("secret"), a.find("devices"))
  end

  # import cloud : par defaut, les appareils trouves par la derniere recherche
  def start_cloud(region, key, secret, ids)
    if self.cloud != nil  raise "tuya_error", "import cloud deja en cours"  end
    if self.scan != nil  raise "tuya_error", "recherche en cours : reessayer a la fin"  end
    if ids == nil
      ids = []
      if self.scan_result != nil
        for r: self.scan_result  ids.push(r["id"])  end
      end
    end
    if size(ids) == 0  raise "tuya_error", "aucun appareil : lancer d'abord une recherche (TuyaScan)"  end
    self.check_heap(self.CLOUD_MIN_HEAP)
    self.cloud = TuyaCloud(region, key, secret, ids)
    self.cloud_t = 0
    return f"import cloud lance pour {size(ids)} appareil(s)"
  end

  # une requete du cloud par seconde (chacune bloque le temps de la poignee de main TLS)
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

  ###################### endpoints Matter ######################
  # liaisons sans endpoint Matter du meme nom ; nil si Matter n'est pas actif
  def matter_missing()
    import global
    import string
    if !global.contains("matter_device")  return nil  end
    var md = global.matter_device
    if md == nil || md.plugins_config == nil  return nil  end
    var names = {}
    for c: md.plugins_config
      var n = c.find("name")
      if n != nil  names[string.tolower(n)] = true  end
    end
    var miss = []
    for d: self.devices
      for n: d.nodes()
        for b: n.bindings
          var k = string.tolower(b.ep)
          if !names.contains(k)
            miss.push(b)
            names[k] = true
          end
        end
      end
    end
    return miss
  end

  # cree les endpoints Matter virtuels manquants -> noms crees (Restart 1 ensuite pour Google Home)
  def matter_create()
    import global
    var miss = self.matter_missing()
    if miss == nil  raise "tuya_error", "Matter n'est pas actif"  end
    var added = []
    for b: miss
      var t = TuyaImport.MATTER_TYPES.find(b.type)
      if t == nil  continue  end
      if global.matter_device.bridge_add_endpoint(t, {"name": b.ep}) != nil  added.push(b.ep)  end
    end
    return added
  end

  def matter_cmd()
    var added = self.matter_create()
    return {"Added": added, "Restart": size(added) > 0 ? "Restart 1 pour que Google Home les voie" : ""}
  end

  def load_config()
    import string
    import json
    for d: self.devices  d.close("rechargement")  end
    self.devices = []
    self.by_ep = {}
    var conf
    try
      var f = open(self.CONFIG, "r")
      conf = json.load(f.read())
      f.close()
    except .. as e, m
      tasmota.log(f"TUY: lecture de {self.CONFIG} impossible : {m}", 1)
      return
    end
    if conf == nil
      tasmota.log(f"TUY: {self.CONFIG} n'est pas un JSON valide", 1)
      return
    end
    for c: conf.find("devices", [])
      if c.find("enabled", true) == false  continue  end
      if c.find("ip", "") == "" || !c.contains("key") || !c.contains("id")
        tasmota.log(f"TUY: appareil incomplet ignore : {c.find('name')}", 1)
        continue
      end
      var d = TuyaDevice(c)
      self.devices.push(d)
      for n: d.nodes()
        for b: n.bindings
          self.by_ep[string.tolower(b.ep)] = b
        end
      end
    end
    tasmota.log(f"TUY: {size(self.devices)} appareil(s), {size(self.by_ep)} endpoint(s) Matter", 2)
  end

  def every_50ms()
    for d: self.devices
      try
        d.loop()
      except .. as e, m
        tasmota.log(f"TUY: {d.name} erreur : {e} {m}", 2)
        d.close("erreur interne")
      end
    end
    var now = tasmota.millis()
    if self.scan != nil
      var running = false
      try
        running = self.scan.loop()
      except .. as e, m
        tasmota.log(f"TUY: recherche : {e} {m}", 2)
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
        tasmota.log(f"TUY: renvoi vers Matter : {e} {m}", 2)
      end
    end
  end

  # renvoie l'etat complet aux endpoints Matter qui ont refuse un MtrUpdate : un endpoint cree
  # alors que le driver tourne recoit ainsi l'etat de l'appareil sans redemarrage
  def sync_pending()
    for d: self.devices
      for n: d.nodes()
        for b: n.bindings
          if b.pending  b.push(n.dps)  end
        end
      end
    end
  end

  # evenement MtrReceived : {"ep9":{"Ep":9,"Name":"Lumiere","Power":1}}
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

  # TuyaSend <appareil>,<dp ou code>,<valeur JSON | toggle>   ex : TuyaSend Ventilateur,60,true
  def cmd_send(payload)
    import string
    import json
    var a = string.split(payload, ",", 2)
    if size(a) < 3  return tasmota.resp_cmnd_str("Syntaxe : TuyaSend <appareil>,<dp ou code>,<valeur|toggle>")  end
    var n = self.find_node(self.trim(a[0]))
    if n == nil  return tasmota.resp_cmnd_str("Appareil inconnu")  end
    var v = json.load(a[2])
    if v == nil  v = a[2]  end
    var dp = self.trim(a[1])
    var num = int(dp)
    if str(num) != dp                         # code de DP (switch_led...) : "codes" de l'import
      var c = (n.codes != nil) ? n.codes.find(dp) : nil
      if c == nil  return tasmota.resp_cmnd_str("DP inconnu : " + dp)  end
      num = int(c)
    end
    if string.tolower(self.trim(a[2])) == "toggle"   # inverse un DP booleen (bouton Zigbee...)
      var cur = n.dps.find(str(num))
      if type(cur) != 'bool'
        return tasmota.resp_cmnd_str(cur == nil ? "toggle : etat du DP inconnu" : "toggle : DP non booleen")
      end
      v = !cur
    end
    var dps = {}
    dps[str(num)] = v
    if n.conn.set_dps(n, dps)
      tasmota.resp_cmnd_done()
    else
      tasmota.resp_cmnd_str("Appareil non connecte")
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
    if f != "" && size(r) == 0  return tasmota.resp_cmnd_str("Appareil inconnu")  end
    tasmota.resp_cmnd(json.dump({"TuyaStatus": r}))
  end

  def cmd_reload()
    self.load_config()
    tasmota.resp_cmnd_done()
  end

  # mesures (capteurs) dans le releve SENSOR
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

  # entier Tuya / diviseur (puissance de 10) en decimal exact : 2268703 / 100 -> "22687.03"
  # (pas de flottant : Berry calcule en simple precision sur l'ESP32)
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
  end
end

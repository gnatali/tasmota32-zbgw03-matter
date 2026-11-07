# Harnais de test : simule `tasmota` et `tcpclientasync`, pilote par des lignes sur stdin
#   RX <ip> <hex>     octets recus de l'appareil
#   OPEN <ip>         la connexion TCP aboutit        DROP <ip>   l'appareil coupe
#   ADV <ms>          avance le temps (every_50ms appele toutes les 50 ms)
#   MTR <json>        evenement MtrReceived            CMD <nom> <payload>  commande Tasmota
#   SENSOR            json_append() + web_sensor()     END
#   EPADD <nom>       cree l'endpoint Matter <nom> (absent au depart : "Inconnu")
#   UDP <port> <ip> <hex>   paquet UDP recu sur <port>     HEAP <Ko>   memoire libre simulee
#   HTTPSRESP <chemin> <code> <corps>   reponse du faux cloud Tuya pour <chemin>
#   HTTP <GET|POST> <chemin> <json des arguments>   requete a la page web du driver (PAGE ...)
#   WEBBTN            bouton de la page Configuration
# Sorties : CONNECT, TX, CLOSE, CMD (MtrUpdate), PUB, RESP, APPEND, WEB, LOG, UDPBIND, UDPTX,
#   UDPCLOSE, HTTPS, MATTERADD, PAGE ; READY apres chaque ligne
import json
import string
import webserver

class MockTasmota
  var now, rules, cmds, drivers, missing, heap
  def init()  self.now = 100000  self.rules = {}  self.cmds = {}  self.drivers = []  self.missing = {"Inconnu": true}  self.heap = 60  end
  def millis()  return self.now  end
  def memory()  return {"heap_free": self.heap}  end
  def eth()  return {"ip": "10.0.0.2"}  end
  def wifi()  return {}  end
  def rtc()  return {"utc": 1793984000 + self.now / 1000}  end
  def add_driver(d)  self.drivers.push(d)  end
  def add_rule(t, f, id)  self.rules[t] = f  end
  def add_cmd(n, f)  self.cmds[n] = f  end
  def log(m, l)  print("LOG " + str(l) + " " + m)  end
  def publish_result(p, sub)  print("PUB " + p)  end
  def cmd(c, mute)
    print("CMD " + c)
    var p = json.load(c[10 ..])
    if self.missing.contains(p["Name"])  return {"MtrUpdate": "Invalid Device"}  end
    if p["Name"] == "Ventilateur"  return {"MtrUpdate": "Done"}  end     # v_fan : pas d'etat publie
    return {"MtrUpdate": p}
  end
  def resp_cmnd(s)  print("RESP " + s)  end
  def resp_cmnd_str(s)  print("RESP " + s)  end
  def resp_cmnd_done()  print("RESP Done")  end
  def response_append(s)  print("APPEND " + s)  end
  def web_send_decimal(s)  print("WEB " + s)  end
end
tasmota = MockTasmota()

class tcpclientasync
  static var socks = {}
  var ip, st, inbox
  def init()  self.inbox = bytes()  end
  def connect(ip, port)
    self.ip = ip
    tcpclientasync.socks[ip] = self
    print("CONNECT " + ip + " " + str(port))
    return true
  end
  def connected()  return self.st  end
  def available()  return size(self.inbox)  end
  def readbytes()  var b = self.inbox  self.inbox = bytes()  return b  end
  def write(b)
    # ecrit au plus 64 octets a la fois, pour tester les ecritures partielles
    var n = size(b) > 64 ? 64 : size(b)
    print("TX " + self.ip + " " + b[0 .. n - 1].tohex())
    return n
  end
  def close()
    print("CLOSE " + self.ip)
    self.st = false
  end
end

# UDP : un faux socket par port, paquets recus pousses par le harnais
class udp
  static var socks = {}
  var port, inbox, remote_ip, remote_port
  def init()  self.inbox = []  end
  def begin(host, port)
    self.port = port
    udp.socks[port] = self
    print("UDPBIND " + str(port))
    return true
  end
  def read()
    if size(self.inbox) == 0  return nil  end
    var x = self.inbox[0]
    self.inbox.remove(0)
    self.remote_ip = x[0]
    return x[1]
  end
  def send(host, port, b)  print("UDPTX " + host + " " + str(port) + " " + b.tohex())  return true  end
  def close()
    udp.socks.remove(self.port)
    print("UDPCLOSE " + str(self.port))
  end
end

# client HTTPS : reponses preparees par chemin, requetes affichees avec leurs en-tetes
class webclient
  static var responses = {}
  var url, headers, resp
  def init()  self.headers = {}  end
  def begin(url)  self.url = url  return true  end
  def add_header(k, v)  self.headers[k] = v  end
  def GET()
    print("HTTPS " + self.url + " " + json.dump(self.headers))
    var i = string.find(self.url, "/", 8)
    self.resp = webclient.responses.find(self.url[i ..])
    return (self.resp != nil) ? self.resp[0] : 404
  end
  def get_string()  return self.resp[1]  end
  def close()  end
end

# Matter : configuration des endpoints, comme matter_device de Tasmota
class MockMatter
  var plugins_config, next_ep
  def init()  self.plugins_config = {"1": {"type": "v_light2", "name": "Porche"}}  self.next_ep = 2  end
  def bridge_add_endpoint(t, conf)
    var c = {"type": t}
    for k: conf.keys()  c[k] = conf[k]  end
    self.plugins_config[str(self.next_ep)] = c
    self.next_ep += 1
    print("MATTERADD " + json.dump(c))
    return self.next_ep - 1
  end
end
matter_device = MockMatter()

# Le driver est instancie ici comme dans autoexec.be : le fichier ne contient que les classes.
# Interpreteur avec le driver solidifie : les classes sont deja natives. Sinon, le source est
# compile en mode strict, comme load() dans Tasmota.
import global
if !global.contains("TuyaLocal")
  import strict
  compile("../tuya_local.be", "file")()
end
global.tuya_local = global.TuyaLocal()
var drv = global.tuya_local
print("READY")

def tick()  drv.every_50ms()  end

while true
  var line = input()
  if line == nil || line == "END"  break  end
  var sp = string.split(line, " ", 1)
  var op = sp[0]
  var arg = size(sp) > 1 ? sp[1] : ""
  if op == "RX"
    var a = string.split(arg, " ", 1)
    tcpclientasync.socks[a[0]].inbox .. bytes(a[1])
  elif op == "OPEN"
    tcpclientasync.socks[arg].st = true
  elif op == "DROP"
    tcpclientasync.socks[arg].st = false
  elif op == "ADV"
    var ms = int(arg)
    while ms > 0
      tasmota.now += 50
      ms -= 50
      tick()
    end
  elif op == "MTR"
    tasmota.rules["MtrReceived"](json.load(arg), "MtrReceived", nil)
  elif op == "CMD"
    var a = string.split(arg, " ", 1)
    tasmota.cmds[a[0]](a[0], 0, size(a) > 1 ? a[1] : "")
  elif op == "MEM"
    import gc
    gc.collect()
    print("MEM " + str(gc.allocated()))
  elif op == "EPADD"
    tasmota.missing.remove(arg)
  elif op == "UDP"
    var a = string.split(arg, " ", 2)
    udp.socks[int(a[0])].inbox.push([a[1], bytes(a[2])])
  elif op == "HEAP"
    tasmota.heap = int(arg)
  elif op == "HTTPSRESP"
    var a = string.split(arg, " ", 2)
    webclient.responses[a[0]] = [int(a[1]), a[2]]
  elif op == "HTTP"
    var a = string.split(arg, " ", 2)
    webserver._args = json.load(a[2])
    webserver._out = []
    webserver._routes[a[1] + ":" + a[0]]()
    print("PAGE " + json.dump(webserver._out.concat("")))
  elif op == "WEBBTN"
    webserver._out = []
    drv.web_add_config_button()
    print("PAGE " + json.dump(webserver._out.concat("")))
  elif op == "SENSOR"
    drv.json_append()
    drv.web_sensor()
  end
  tick()
  print("READY")
end

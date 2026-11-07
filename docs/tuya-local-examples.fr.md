# Driver Tuya local : exemples de commandes et d'événements

*English version: [tuya-local-examples.en.md](tuya-local-examples.en.md)*

Exemples d'utilisation du driver Tuya local de la ZB-GW03 : commandes, réponses, événements,
règles et scripts Berry. Les identifiants, adresses et réponses sont fictifs mais ont le format
exact du driver ; aucune clé n'y figure (le driver les remplace par `***`). Fonctionnement
détaillé : [tuya-local.fr.md](tuya-local.fr.md) et [tuya-local-dev.fr.md](tuya-local-dev.fr.md).

Appareils des exemples : `Ventilateur` (3.5 ; DP 60 marche, 62 vitesse, 20 lumière),
`Récepteur radio` (3.5 ; DP 1 à 4), `Entrée-Porche` (ampoule 3.3 ; DP 20 à 23), bouton Zigbee
SNZB-01P `0x922D` sur la ZB-GW03.

## Sommaire

1. [Où envoyer les commandes](#1-où-envoyer-les-commandes)
2. [Consulter](#2-consulter)
3. [Piloter un appareil](#3-piloter-un-appareil)
4. [Ajouter, modifier, supprimer](#4-ajouter-modifier-supprimer)
5. [Rechercher et importer](#5-rechercher-et-importer)
6. [Matter](#6-matter)
7. [Événements](#7-événements)
8. [Messages de la console](#8-messages-de-la-console)
9. [Règles Tasmota](#9-règles-tasmota)
10. [Scripts Berry](#10-scripts-berry)

## 1. Où envoyer les commandes

| Canal | Envoi | Réponse |
|---|---|---|
| Console web | `TuyaStatus` | `RSL: RESULT = {"TuyaStatus":{...}}` |
| HTTP | `http://192.168.1.13/cm?cmnd=TuyaStatus` | corps JSON `{"TuyaStatus":{...}}` |
| MQTT | sujet `cmnd/<topic>/TuyaStatus`, message vide | sur `stat/<topic>/RESULT` |

En HTTP, encoder les espaces et le JSON (`curl -G --data-urlencode`), et ajouter
`user=admin&password=...` si un mot de passe web est défini (`WebPassword`) :

```bash
curl "http://192.168.1.13/cm?cmnd=TuyaSend%20Ventilateur,60,true"
curl -G "http://192.168.1.13/cm" --data-urlencode "user=admin" --data-urlencode "password=xxx" \
     --data-urlencode 'cmnd=TuyaStatus Entrée-Porche'
```

En MQTT (`mosquitto` par exemple) :

```bash
mosquitto_sub -h broker -t 'stat/<topic>/RESULT' -v &
mosquitto_pub -h broker -t 'cmnd/<topic>/TuyaSend' -m 'Ventilateur,62,3'
```

## 2. Consulter

**État de tous les appareils** :

```
TuyaStatus
```
```json
{"TuyaStatus":{
  "Ventilateur":{"Connected":true,"Ip":"192.168.1.20","Version":"3.5","Dps":{"20":false,"60":true,"62":3,"63":"forward"}},
  "Récepteur radio":{"Connected":true,"Ip":"192.168.1.23","Version":"3.5","Dps":{"1":false,"2":false,"3":false,"4":false}},
  "Entrée-Porche":{"Connected":false,"Ip":"192.168.1.174","Version":"3.3","Dps":{}}}}
```

**Un seul appareil** (nom sans casse, ou identifiant) : `TuyaStatus entrée-porche`. Inconnu :
`{"TuyaStatus":"Appareil inconnu"}`.

**Configuration sans les clés** : `TuyaConfig`, ou `TuyaConfig Ventilateur` pour un appareil :

```json
{"TuyaConfig":{"name":"Ventilateur","id":"00000000000000fan001","key":"***","ip":"192.168.1.20",
 "version":"3.5","matter":[{"ep":"Ventilateur","type":"fan","dp":60,"dp_speed":62,"speed_min":1,"speed_max":6},
                           {"ep":"Lumière ventilateur","type":"light0","dp":20}]}}
```

## 3. Piloter un appareil

| Commande | Effet |
|---|---|
| `TuyaSend Ventilateur,60,true` | marche |
| `TuyaSend Ventilateur,62,3` | vitesse 3 |
| `TuyaSend Ventilateur,63,"reverse"` | valeur texte (JSON) |
| `TuyaSend Ventilateur,20,toggle` | inverse la lumière du ventilateur |
| `TuyaSend Lampe,switch_led,true` | par code de DP (appareil importé, avec une table `codes`) |
| `TuyaSend Lampe,bright_value_v2,500` | luminosité par code |

Réponses : `{"TuyaSend":"Done"}` si la commande est partie, sinon :

| Réponse | Cause |
|---|---|
| `Appareil inconnu` | aucun appareil de ce nom ou de cet identifiant |
| `Appareil non connecte` | appareil hors ligne (la commande n'est pas envoyée) |
| `DP inconnu : xxx` | code absent de la table `codes` de l'appareil |
| `toggle : etat du DP inconnu` | l'appareil n'a pas encore envoyé ce DP |
| `toggle : DP non booleen` | `toggle` sur une valeur qui n'est pas vrai/faux |
| `Syntaxe : TuyaSend <appareil>,<dp ou code>,<valeur\|toggle>` | arguments manquants |

## 4. Ajouter, modifier, supprimer

**Ajouter** une ampoule à température de couleur réglable (clé locale de 16 caractères) :

```
TuyaAdd {"name":"Lampe bureau","id":"00000000000000lamp01","key":"<clé locale>","ip":"192.168.1.40","version":"3.3","matter":[{"ep":"Lampe bureau","type":"light2","dp":20,"dp_mode":21,"dp_bri":22,"dp_ct":23}]}
```
```json
{"TuyaAdd":"Lampe bureau"}
```

**Modifier** sans retaper la clé : `"key":"***"` (ou sans `key`) conserve la clé enregistrée.

```
TuyaAdd {"name":"Lampe bureau","id":"00000000000000lamp01","key":"***","ip":"192.168.1.41","version":"3.3","matter":[{"ep":"Lampe bureau","type":"light2","dp":20,"dp_mode":21,"dp_bri":22,"dp_ct":23}]}
```

**Supprimer** : `TuyaDel Lampe bureau` → `{"TuyaDel":"Lampe bureau"}`.
**Relire** `tuya.json` modifié à la main : `TuyaReload` → `{"TuyaReload":"Done"}`.

Chaque écriture garde l'ancienne version dans `/tuya.json.bak`. Erreurs possibles :
`{"TuyaAdd":{"Error":"name et id requis"}}`, `"cle locale (key) requise"`,
`"nom ou id deja utilise"`, `"/tuya.json n'est pas un JSON valide : non modifie"`.

## 5. Rechercher et importer

**Rechercher** les appareils sur le réseau (20 s par défaut, 60 au plus) :

```
TuyaScan 30
```
```json
{"TuyaScan":"recherche lancee pour 30 s"}
```

À la fin, événement (MQTT `stat/<topic>/RESULT` et règles) :

```json
{"TuyaScan":{"Devices":[
  {"id":"00000000000000fan001","ip":"192.168.1.20","version":"3.5","product_key":"keyfan0000000000"},
  {"id":"0000000000000porch01","ip":"192.168.1.174","version":"3.3","product_key":"keyporch00000000"}]}}
```

**Importer** le `devices.json` de `tinytuya wizard` (envoyé par Outils → Gestion des fichiers) :

| Commande | Appareils importés |
|---|---|
| `TuyaImport` | ceux de la dernière recherche ou déjà configurés, depuis `/devices.json` |
| `TuyaImport all` | tous |
| `TuyaImport 00000000000000fan001,0000000000000porch01` | ceux-là |
| `TuyaImport /autre.json all` | tous, depuis un autre fichier |

```json
{"TuyaImport":{"Added":["Lampe bureau"],"Updated":["Ventilateur","Entrée-Porche"],"Skipped":[]}}
```

**Importer par le cloud Tuya** (projet Tuya IoT : Access ID et Access Secret ; appareils de la
dernière recherche, ou liste `devices`). La console web journalise la commande avec le secret :
préférer la page **Tuya local**, ou MQTT / HTTP.

```
TuyaCloud {"region":"eu","id":"<Access ID>","secret":"<Access Secret>"}
TuyaCloud {"region":"eu","id":"<Access ID>","secret":"<Access Secret>","devices":["00000000000000lamp01"]}
```
```json
{"TuyaCloud":"import cloud lance pour 3 appareil(s)"}
```

Une requête par seconde, puis l'événement de fin :

```json
{"TuyaCloud":{"Added":["Lampe bureau"],"Updated":["Ventilateur"],"Skipped":[]}}
{"TuyaCloud":{"Error":"cloud Tuya : sign invalid"}}
```

Autres erreurs : `"memoire libre insuffisante : 30 Ko, 35 Ko necessaires"`,
`"heure non synchronisee (NTP)"`, `"region inconnue (eu, we, us, ue, cn, in, sg)"`,
`"aucun appareil : lancer d'abord une recherche (TuyaScan)"`, `"cloud Tuya : HTTP 404"`.

## 6. Matter

**Créer les endpoints Matter manquants** (un par liaison `matter`, du type correspondant) :

```
TuyaMatter
```
```json
{"TuyaMatter":{"Added":["Lampe bureau"],"Restart":"Restart 1 pour que Google Home les voie"}}
```

Puis `Restart 1` : sans redémarrage, Google Home affiche les nouveaux appareils hors ligne.

**Ce que fait le driver** : une commande de Google Home arrive par l'événement `MtrReceived`
et part vers l'appareil Tuya (journal `TUY: Matter 'Ventilateur' -> Ventilateur {"60":true,"62":3}`) ;
un changement sur l'appareil part vers Matter par `MtrUpdate {"Name":"Ventilateur","FanSpeed":50}`.

## 7. Événements

**Changement d'état d'un appareil** (MQTT `stat/<topic>/RESULT`, console `RSL: RESULT = ...`,
règles) : seulement les DP qui ont changé, ou tout l'état à la connexion.

```json
{"Tuya":{"Name":"Ventilateur","Dps":{"62":3}}}
{"Tuya":{"Name":"Entrée-Porche","Dps":{"20":true,"21":"white","22":1000,"23":0}}}
```

**Relevés** (appareils avec `sensors`, par exemple une pince ampèremétrique), dans le message
`tele/<topic>/SENSOR` et sur la page d'accueil :

```json
{"Time":"2026-11-07T18:30:00","Tuya":{"Pince":{"Energie":22687.03,"Puissance":592,"Tension A":235.0}}}
```

**Fins d'opération** : `{"TuyaScan":{"Devices":[...]}}` et `{"TuyaCloud":{...}}` (voir § 5).

## 8. Messages de la console

| Message | Signification |
|---|---|
| `TUY: demarrage du driver, memoire libre 73 Ko` | `autoexec.be` démarre le driver |
| `TUY: 3 appareil(s), 5 endpoint(s) Matter` | configuration chargée |
| `TUY: Ventilateur (192.168.1.20) connecte, protocole 3.5` | connexion établie |
| `TUY: Ventilateur (192.168.1.20) deconnecte : plus de reponse` | appareil muet 35 s ; reconnexion automatique |
| `TUY: Ventilateur non connecte, commande ignoree` | commande pendant une déconnexion |
| `TUY: endpoint Matter 'Lampe' : Invalid Device (nouvel essai toutes les 30 s)` | endpoint Matter absent (nom différent ou pas encore créé) |
| `TUY: endpoint Matter 'Lampe' disponible, etat envoye` | l'endpoint accepte, état envoyé |
| `TUY: appareil incomplet ignore : Pergola 1` | entrée sans `ip`, `key` ou `id` |
| `TUY: TuyaScan {"Devices":[...]}` | fin de recherche |
| `TUY: import : objet JSON trop gros, ignore` | entrée de plus de 8 Ko dans `devices.json` |

## 9. Règles Tasmota

**Bouton Zigbee SNZB-01P → appareils Tuya** (`Power` 2 : appui simple, 1 : double, 0 : long).
`Rule1` reste libre pour le bouton virtuel Matter ; les deux règles se déclenchent :

```
Rule2 on ZbReceived#0x922D#Power=2 do TuyaSend Entrée-Porche,20,toggle endon on ZbReceived#0x922D#Power=1 do TuyaSend Ventilateur,20,toggle endon on ZbReceived#0x922D#Power=0 do TuyaSend Récepteur radio,1,toggle endon
Rule2 1
```

**Interrupteur Zigbee à deux positions** :

```
Rule2 on ZbReceived#0x1234#Power=1 do TuyaSend Entrée-Porche,20,true endon on ZbReceived#0x1234#Power=0 do TuyaSend Entrée-Porche,20,false endon
```

**Réagir à un appareil Tuya** : `Tuya#Dps#<dp>` se déclenche pour **tout** appareil qui envoie ce
DP (la règle ne voit pas le nom) ; à réserver à un DP propre à un seul appareil :

```
Rule3 on Tuya#Dps#62 do Publish stat/ventilateur/vitesse %value% endon
Rule3 1
```

**Tous les soirs à 23 h, éteindre le ventilateur** (indépendant de Google Home et d'internet) :

```
Rule3 on Time#Minute=1380 do TuyaSend Ventilateur,60,false endon
```

## 10. Scripts Berry

**`autoexec.be` complet** : démarrage différé du driver, puis liens Zigbee ↔ Tuya.

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

  # appui simple sur le bouton 0x922D : inverse la lumiere Entree-Porche
  tasmota.add_rule("ZbReceived#0x922D#Power=2", def (v)
    tasmota.cmd("TuyaSend Entrée-Porche,20,toggle")
  end)

  # Entree-Porche allumee ou eteinte : la lumiere Zigbee "Salon" suit
  tasmota.add_rule("Tuya", def (v)
    if v.find("Name") == "Entrée-Porche" && v["Dps"].contains("20")
      tasmota.cmd('ZbSend {"Device":"Salon","Send":{"Power":' + (v["Dps"]["20"] ? "1" : "0") + '}}')
    end
  end)
end
tasmota.set_timer(30000, tuya_start)
```

Attention aux boucles : si la lumière Zigbee commande à son tour Entrée-Porche, ne relayer que
si l'état diffère.

**Depuis la console Berry** (`Br ...`), l'objet du driver est `tuya_local` :

```berry
Br tuya_local.find_node("Ventilateur").dps          # dernier etat connu
Br for d: tuya_local.devices  print(d.name, d.ip, d.state == d.ST_READY)  end
Br var n = tuya_local.find_node("Ventilateur")  n.conn.set_dps(n, {"60": true, "62": 2})
Br tuya_local.scan_result                            # resultat de la derniere recherche
```

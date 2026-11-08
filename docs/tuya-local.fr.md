# Appareils Tuya en local (équivalent de LocalTuya)

*English version (reference): [tuya-local.en.md](tuya-local.en.md)*

Le driver Berry `berry/tuya_local.be` pilote les appareils Tuya **sans les flasher et sans le
cloud**, directement sur le réseau local, et les présente à **Matter** (Google Home, Apple
Maison...) à travers la passerelle.

Exemples de commandes, d'événements, de règles et de scripts :
[tuya-local-examples.fr.md](tuya-local-examples.fr.md) ; fonctionnement interne :
[tuya-local-dev.fr.md](tuya-local-dev.fr.md).

- Protocoles locaux Tuya **3.3, 3.4 et 3.5** (TCP 6668, chiffrement par la clé locale).
- **Sous-appareils Zigbee d'une passerelle Tuya** (prises, interrupteurs, capteurs restés
  appairés à la passerelle Tuya).
- Pont Matter : chaque fonction d'un appareil Tuya devient un **endpoint Matter virtuel**.
  Une commande de Google Home part vers l'appareil Tuya, et un changement fait sur l'appareil
  (bouton, application Smart Life, télécommande) remonte dans Google Home.
- Mesures (pince ampèremétrique...) dans les relevés `SENSOR` de Tasmota et sur la page
  d'accueil.

Il nécessite un firmware de ce dépôt qui contient le correctif `berry-aes-gcm-128-aad.patch`
et l'option `USE_BERRY_CRYPTO_AES_CBC` (le firmware officiel de Tasmota ne sait pas chiffrer
le protocole 3.5).

## Sommaire

- [Préparer les appareils](#préparer-les-appareils)
- [Installer le driver](#installer-le-driver)
- [Page web : ajouter et gérer les appareils](#page-web--ajouter-et-gérer-les-appareils)
- [Créer les endpoints Matter](#créer-les-endpoints-matter)
- [Fichier de configuration](#fichier-de-configuration)
- [Commandes](#commandes)
- [Liens directs avec un bouton Zigbee](#liens-directs-avec-un-bouton-zigbee)
- [Déplacer des appareils Zigbee sur la ZB-GW03](#déplacer-des-appareils-zigbee-sur-la-zb-gw03)
- [Limites](#limites)
- [Tests](#tests)

## Préparer les appareils

Les appareils peuvent maintenant être trouvés et importés **depuis la passerelle** (voir
[Page web](#page-web--ajouter-et-gérer-les-appareils)) : seule la clé locale demande le cloud
Tuya, une fois. Avec TinyTuya sur un PC, la démarche reste possible :

1. **Clés locales** : sur un PC, `py -m pip install tinytuya` puis `py -m tinytuya wizard`
   (compte développeur Tuya IoT lié à l'application Smart Life). Le fichier `devices.json`
   produit contient, pour chaque appareil, son `id`, sa clé locale `key` et, pour les
   sous-appareils Zigbee, leur `node_id` (le `cid` du driver).
2. **Adresses et versions** : `py -m tinytuya scan` écrit `snapshot.json` avec l'adresse IP
   (`ip`) et la version du protocole (`ver`) de chaque appareil Wi-Fi qui répond.
3. **Adresses fixes** : réserver l'adresse IP de chaque appareil Wi-Fi dans le serveur DHCP
   (la box), sinon le driver perd l'appareil quand son adresse change.

La clé locale change à chaque nouvel appairage dans Smart Life : relancer alors le `wizard`
et mettre à jour `tuya.json`.

## Installer le driver

1. Mettre à jour la passerelle avec un firmware de ce dépôt. Le driver y est **intégré**
   (solidifié) : son code est en flash, au lieu d'être compilé en RAM au chargement. Il n'y a
   plus de fichier `tuya_local.be` à envoyer (en supprimer une ancienne copie est sans
   risque : il n'est chargé que si le firmware ne contient pas le driver).
2. **Outils → Gestion des fichiers** : envoyer `tuya.json` (ou créer les appareils plus tard
   depuis la page : recherche et import).
3. **Activer le driver**, comme Matter : **Configuration → 🔌 Tuya Local**, cocher **Tuya Local
   enable**, **💾 Save** (ou la commande `TuyaEnable 1`). Le réglage est gardé d'un redémarrage
   à l'autre (`_persist.json`). **Aucun `autoexec.be` n'est nécessaire** : le firmware instancie
   le driver au démarrage, comme le `matter_device` de Matter, et le driver attend lui-même le
   bon moment. C'est activé à la compilation par la directive `USE_TUYA_LOCAL` (comme
   `USE_MATTER_DEVICE` pour Matter), définie dans le `platformio_override.ini` de ce dépôt.
4. À chaque démarrage, le driver ne se connecte aux appareils qu'une fois **Zigbee démarré** (ou
   absent), le **réseau** disponible, **Matter** démarré (s'il est activé) et au moins **45 Ko**
   de mémoire libres. En attendant, la page d'accueil affiche un bouton **⏳ Tuya Local** grisé
   avec ce qu'il attend (comme les boutons de Zigbee pendant son initialisation) ; le bouton
   devient ensuite **🔌 Tuya Local** et ouvre la page. La console affiche :

   ```
   TUY: waiting for Zigbee
   TUY: starting, free memory 72 KB
   TUY: 5 device(s), 16 Matter endpoint(s)
   TUY: Ventilateur (192.168.1.18) connected, protocol 3.5
   ...
   ```

5. `TuyaStatus` liste chaque appareil avec `"Connected":true` et ses valeurs. Vérifier la
   mémoire libre (`Heap` dans `Status 4`) une fois tous les appareils connectés : la
   ZB-GW03 n'a pas de PSRAM.

**Avec un `autoexec.be` qui démarrait le driver** (`tuya_start()`, `global.tuya_local =
TuyaLocal()`, `load("tuya_local.be")`) : supprimer ces lignes, puis activer le driver comme
ci-dessus. Si elles restent, elles créent une seconde instance qui ne fait rien, sinon journaliser
`TUY: driver already started by the firmware: remove the tuya_local lines from autoexec.be`,
et `tuya_local` dans la console Berry désigne alors cette instance inactive. De toute façon, il
ne faut pas démarrer le driver directement dans `autoexec.be` : sur la ZB-GW03 (sans PSRAM), le
charger pendant que Zigbee et Matter démarraient a fait planter l'ESP32 ; après quatre
plantages rapides, la protection contre les boucles de redémarrage de Tasmota démarre **sans
Berry** (donc sans Matter) et **désactive toutes les règles**.

Pour arrêter le driver : décocher la case (ou `TuyaEnable 0`) : les connexions sont fermées
aussitôt.

## Page web : ajouter et gérer les appareils

**Configuration → 🔌 Tuya Local** (`/tuya`), ou le bouton **🔌 Tuya Local** de la page d'accueil
une fois le driver démarré. Comme le reste de Tasmota, la page est en anglais, avec la mise en
page des pages de Tasmota (340 px de large) et des pictogrammes pour les actions. Les messages
des commandes, les réponses et le journal sont aussi en anglais.

- **Tuya Local** : case **Tuya Local enable** et état du driver (🟢 démarré, ⏳ ce qu'il
  attend, ⚪ désactivé). Tant que le driver ne tourne pas, les appareils affichent ⏸ et la
  section Matter est vide.

- **Tuya devices** : nom, IP, version et état de chaque entrée de `tuya.json` (🟢 connecté,
  🔴 déconnecté, ⚪ désactivé, ⚠ incomplet). **📝** ouvre l'entrée en JSON (même format que le
  fichier) : la clé y est remplacée par `***`, et une clé laissée à `***` est conservée à
  l'enregistrement (**💾 Save** ; **🔥 Delete** supprime l'appareil). **➕ Add device** propose
  un modèle. Chaque enregistrement garde l'ancienne version dans `/tuya.json.bak`, puis recharge
  la configuration. **🔄 Reload tuya.json** relit le fichier.
- **Network discovery → 🔍 Discover devices (20 s)** : écoute les annonces des appareils Wi-Fi sur le réseau
  local (ports UDP 6666, 6667, 7000) et demande aux appareils 3.5 de s'annoncer, comme
  `tinytuya scan`. Donne l'identifiant, l'IP et la version de chacun (✅ déjà configuré, 🆕
nouveau). La passerelle et les
  appareils doivent être sur le **même réseau local** (les annonces ne traversent pas un routeur).
- **Import local keys**, deux possibilités :
  - **📥 Import file** : le `devices.json` de `tinytuya wizard`, envoyé par **Outils → Gestion
    des fichiers**. Il est lu par morceaux : sa taille n'est pas limitée par la mémoire. Sont
    importés les appareils trouvés par la recherche ou déjà configurés (ou tous, case **all**),
    avec leurs sous-appareils Zigbee ;
  - **☁️ Import from cloud** : le cloud Tuya directement, pour les appareils trouvés par la
    recherche. Choisir la région (**Region**) et saisir l'**Access ID** et l'**Access Secret** du
    projet Tuya IoT (le même compte développeur que pour `tinytuya wizard`). Avec la case
    **save credentials**, ils
    sont gardés dans `/tuya_cloud.json` (jamais dans `tuya.json`) : la page reprend ensuite la
    région et l'Access ID, et un Access Secret laissé vide reprend celui enregistré ; le secret
    n'est jamais réaffiché. Décocher la case efface le fichier (l'import en cours se sert encore
    une fois des identifiants). Il faut l'heure à jour
    (NTP) et **35 Ko de mémoire libre** (le client HTTPS de Tasmota en réserve 16) ; l'import
    fait une requête par seconde, le résultat s'affiche sur la page.

  L'import complète `tuya.json` : un nouvel appareil reçoit sa clé, son IP et sa version (de la
  recherche), ses **liaisons Matter déduites de ses DP** (lumière, ventilateur, prise avec ou sans
  mesures, interrupteurs multiples, capteur de température et d'humidité, compteur d'énergie) et
  la table `codes` de ses DP. Un appareil déjà configuré garde ses liaisons : seules sa clé, son
  IP et sa version sont mises à jour. Un appareil sans IP connue est ajouté avec
  `"enabled": false`.
- **Matter endpoints** : une ligne par liaison, comme la liste des appareils : nom de
  l'endpoint, type Matter et, si l'endpoint existe (même nom, sans tenir compte de la casse), ✅
  et son numéro. Un endpoint manquant a une case à cocher (la case de l'en-tête les coche
  toutes). **➕ Create and restart** crée seulement les endpoints cochés (types du tableau
  ci-dessous), puis redémarre Tasmota, ce qui est nécessaire pour Google Home.

## Créer les endpoints Matter

La page **Tuya Local** les crée en un clic (voir ci-dessus). À la main :

Dans **Configuration → Matter**, ajouter un endpoint par entrée `matter` de `tuya.json`, du
type ci-dessous et avec **exactement** le nom donné dans `ep` (32 octets au plus ; une lettre
accentuée compte pour 2). Puis **`Restart 1`, indispensable** : Google Home affiche tout de
suite le nouvel appareil, mais **hors ligne** tant que Tasmota n'a pas redémarré (le contrôleur
ne s'abonne aux nouveaux endpoints qu'à la reconnexion). Le plus simple : créer tous les
endpoints, puis un seul `Restart 1`.

Côté driver, un endpoint qui n'existe pas encore est signalé une fois, et le driver lui renvoie
l'état de l'appareil toutes les 30 s jusqu'à ce qu'il l'accepte. Sans Matter (firmware compilé
sans, ou Matter désactivé), le driver n'envoie rien à Matter : les appareils restent pilotables
par commande, règle et page web, et la page affiche « Matter is not enabled ».

| `type` dans `tuya.json` | Endpoint Matter à créer | Attributs échangés |
|---|---|---|
| `relay` | v.Relay | marche/arrêt |
| `relay_power` | v.Relay+Power | marche/arrêt, puissance, tension, courant |
| `light0` | v.Light 0 OnOff | marche/arrêt |
| `light1` | v.Light 1 Dimmer | marche/arrêt, luminosité |
| `light2` | v.Light 2 CT | marche/arrêt, luminosité, température de couleur |
| `light3` | v.Light 3 RGB | marche/arrêt, luminosité, teinte, saturation |
| `fan` | v.Fan | vitesse (0 = arrêt) |
| `temp` | v.Temperature | température |
| `humidity` | v.Humidity | humidité |

Si un nom ne correspond à aucun endpoint, la console l'indique une fois :
`TUY: Matter endpoint 'xxx': Invalid Device (retry every 30 s)`. Dès que
l'endpoint existe : `TUY: Matter endpoint 'xxx' available, state sent`.

## Fichier de configuration

`tuya.json` (exemple complet sans les clés : [`berry/tuya.example.json`](../berry/tuya.example.json)) :

```json
{"devices": [
  {"name": "Ventilateur", "id": "bf64xxxx...", "key": "clé locale", "ip": "192.168.1.18", "version": "3.5",
   "matter": [
     {"ep": "Ventilateur", "type": "fan", "dp": 60, "dp_speed": 62, "speed_max": 6},
     {"ep": "Lumière ventilateur", "type": "light0", "dp": 20}]},
  {"name": "Gateway", "id": "bf22xxxx...", "key": "clé locale", "ip": "192.168.1.180", "version": "3.3",
   "children": [
     {"name": "Prise Lisseur", "id": "bfc4xxxx...", "cid": "a4c138xxxxxxxxxx",
      "matter": [{"ep": "Prise Lisseur", "type": "relay_power", "dp": 1,
                  "dp_power": 19, "div_power": 10, "dp_voltage": 20, "div_voltage": 10,
                  "dp_current": 18, "div_current": 1000}]}]},
  {"name": "Pince", "id": "bf90xxxx...", "key": "clé locale", "ip": "192.168.1.80", "version": "3.5",
   "sensors": {"Total puissance": [133, 1, "W"], "Total energie": [131, 100, "kWh"]}}
]}
```

**Appareil** (connexion TCP) : `name`, `id`, `key`, `ip`, `version` (`"3.3"`, `"3.4"` ou
`"3.5"`), et `"enabled": false` pour le mettre de côté. Une passerelle Tuya déclare ses
sous-appareils dans `children` (`name`, `id`, `cid` = `node_id` de `devices.json`).

**Entrée `matter`** : `ep` (nom de l'endpoint), `type`, et les numéros de DP (les valeurs par
défaut sont celles des ampoules et ventilateurs Tuya courants) :

| Clé | Rôle | Défaut |
|---|---|---|
| `dp` | marche/arrêt (ou valeur du capteur) | 1 ; 20 pour les lumières ; 60 pour `fan` |
| `dp_mode` | mode (`white` / `colour`) | 21 |
| `dp_bri`, `bri_min`, `bri_max` | luminosité et sa plage | 22, 10, 1000 |
| `dp_ct`, `ct_min`, `ct_max` | température de couleur (0 = chaud, 1000 = froid) et sa plage en mireds | 23, 153, 500 |
| `dp_colour` | couleur au format `colour_data_v2` (`hhhhssssvvvv`) | 24 |
| `dp_speed`, `speed_min`, `speed_max` | vitesse du ventilateur | 62, 1, 6 |
| `div` | diviseur du capteur (`temp`, `humidity`) | 10 |
| `dp_power` / `dp_voltage` / `dp_current` et `div_...` | mesures de `relay_power` | aucun |

La signification des DP de chaque appareil se trouve dans `mapping` de `devices.json`
(`code`, `scale` : un `scale` de 1 donne un diviseur de 10, un `scale` de 3 un diviseur de 1000).

**`sensors`** : `"libellé": [dp, diviseur, "unité"]`. Les valeurs apparaissent dans le relevé
`SENSOR` (`{"Tuya":{"Pince":{"Total puissance":592,...}}}`) et sur la page d'accueil.

## Commandes

| Commande | Effet |
|---|---|
| `TuyaStatus [appareil]` | État des connexions et dernières valeurs de chaque appareil (ou d'un seul) |
| `TuyaSend <appareil>,<dp>,<valeur>` | Envoie une valeur, par exemple `TuyaSend Ventilateur,60,true` ou `TuyaSend Ventilateur,62,3`. Le DP peut aussi être un code (`TuyaSend Lampe,switch_led,true`) si l'appareil a une table `codes` (import). `toggle` inverse un DP booléen : `TuyaSend Entrée-Porche,20,toggle` |
| `TuyaEnable [0\|1]` | Active ou désactive le driver (gardé d'un redémarrage à l'autre), comme la case de la page ; sans argument, donne l'état : `{"TuyaEnable":{"Enabled":true,"State":"running"}}` (`State` : `running`, `disabled`, `waiting for Zigbee`...) |
| `TuyaReload` | Relit `tuya.json` et reconnecte les appareils (driver démarré seulement) |
| `TuyaConfig [appareil]` | Configuration (`tuya.json`) **sans les clés**, ou celle d'un appareil |
| `TuyaAdd <json>` | Ajoute ou remplace un appareil (même format qu'une entrée de `devices`) ; `"key":"***"` ou sans clé : clé conservée |
| `TuyaDel <appareil>` | Supprime un appareil |
| `TuyaScan [secondes]` | Recherche sur le réseau (20 s par défaut, 60 au plus) ; résultat publié à la fin : `{"TuyaScan":{"Devices":[...]}}` |
| `TuyaImport [fichier] [all\|id,id]` | Importe le `devices.json` de tinytuya (`/devices.json` par défaut) |
| `TuyaCloud [json]` | Import depuis le cloud : `{"region":"eu","id":"<Access ID>","secret":"<Access Secret>"}` (et `"devices":[...]` pour choisir les identifiants, `"save":true` pour enregistrer les identifiants, `"save":false` pour les effacer) ; sans argument, identifiants enregistrés ; résultat publié à la fin. **La console web journalise la commande, secret compris** : préférer la page web, ou `TuyaCloud` sans argument une fois les identifiants enregistrés |
| `TuyaMatter [nom,nom]` | Crée les endpoints Matter manquants, tous ou seulement ceux nommés (sans tenir compte de la casse), puis `Restart 1` |

Ces commandes forment l'**API de pilotage à distance** : en HTTP
(`http://<passerelle>/cm?cmnd=TuyaSend%20Ventilateur,60,true`, avec `&user=admin&password=...`
si un mot de passe web est défini) ou en MQTT (`cmnd/<topic>/TuyaSend`). Les réponses sont en
JSON (`{"TuyaAdd":"Lampe"}`, ou `{"TuyaAdd":{"Error":"..."}}`).

Chaque changement d'état est publié sur `stat/<topic>/RESULT` :
`{"Tuya":{"Name":"Ventilateur","Dps":{"62":3}}}`. Les règles peuvent s'en servir.

## Liens directs avec un bouton Zigbee

Une règle Tasmota relie un appareil Zigbee de la ZB-GW03 à un appareil Tuya, **localement** :
sans Google Home, sans cloud ni internet. Exemple avec le bouton Sonoff SNZB-01P `0x922D`
(`Power` 2 : appui simple, 1 : double appui, 0 : appui long) :

```
Rule2 on ZbReceived#0x922D#Power=2 do TuyaSend Entrée-Porche,20,toggle endon on ZbReceived#0x922D#Power=1 do TuyaSend Ventilateur,20,toggle endon on ZbReceived#0x922D#Power=0 do TuyaSend Récepteur radio,1,toggle endon
Rule2 1
```

- Appui simple : lumière Entrée-Porche ; double appui : lumière du ventilateur ; appui long :
  canal 1 du récepteur radio. Le nom est celui de l'appareil dans `tuya.json` (pas celui de
  l'endpoint Matter), le numéro celui du DP.
- `toggle` part de l'état connu du driver : il faut que l'appareil soit connecté et ait déjà
  envoyé cet état (`TuyaStatus <appareil>`).
- Un même bouton peut servir à plusieurs règles : `Rule1` (bouton virtuel Matter « Perron »
  pour Google Home) et `Rule2` se déclenchent toutes les deux. Attention à ne pas créer aussi,
  dans Google Home, une automatisation qui agit sur la même lumière : les deux actions
  s'annuleraient.
- Interrupteur à deux positions : `TuyaSend <appareil>,<dp>,true` et `false` au lieu de `toggle`.

Dans l'autre sens, chaque changement d'état d'un appareil Tuya déclenche les règles
(`{"Tuya":{"Name":...,"Dps":{...}}}`) ; pour filtrer sur le nom de l'appareil, une règle Berry
(`tasmota.add_rule("Tuya", ...)` dans `autoexec.be`) est plus sûre qu'une règle Tasmota.

## Déplacer des appareils Zigbee sur la ZB-GW03

Pour un appareil Zigbee de la passerelle Tuya qu'on préfère piloter directement par la
ZB-GW03 (contrôleurs LED Bureau et Salon, par exemple) :

1. Dans Smart Life, supprimer l'appareil (« Supprimer et effacer les données »).
2. Dans la console de la ZB-GW03 : `ZbPermitJoin 1`.
3. Remettre l'appareil en mode appairage (pour un contrôleur LED, en général plusieurs
   coupures d'alimentation rapprochées : voir sa notice). `ZbInfo` le liste une fois appairé.
4. `ZbName 0x1234,Bureau` pour lui donner un nom.
5. **Configuration → Matter** : ajouter un endpoint **Zig Light 2 CT** (`z_light2`, blanc
   variable), ou **Zig Light 1 Dimmer** (`z_light1`, variateur seul), avec le nom Zigbee en argument.
   Puis `Restart 1`.

Il n'apparaît plus dans Smart Life, et le retirer de `tuya.json` s'il y figurait.

## Limites

- **Une seule connexion locale par appareil** : ne pas utiliser en même temps LocalTuya,
  tuya-local ou TinyTuya sur les mêmes appareils. L'application Smart Life continue de
  fonctionner (par le cloud).
- Couleurs : seul le format `colour_data_v2` (12 caractères hexadécimaux) est géré.
- Import : une température de couleur `temp_value` (ancien format, 0 à 255) n'est pas reprise
  (la lumière devient un variateur), une vitesse de ventilateur en énumération non plus (le
  ventilateur devient un simple marche/arrêt). L'import cloud ne traite pas les sous-appareils
  Zigbee (ils ne s'annoncent pas sur le réseau) : passer par le `devices.json` de tinytuya.
- Les commandes passent quand l'appareil est connecté ; sinon elles sont ignorées (journal :
  `not connected, command ignored`), et le driver se reconnecte tout seul (5 s, puis jusqu'à
  60 s entre deux essais).
- Un appareil muet plus de 35 secondes est déconnecté puis reconnecté.

## Tests

`berry/test/run_tests.sh <dépôt Tasmota>` compile l'interpréteur Berry de Tasmota avec le
chiffrement BearSSL de Tasmota, et joue 21 scénarios contre de faux appareils Tuya construits
sur [TinyTuya](https://github.com/jasonacox/tinytuya) (3.3, 3.4, 3.5, passerelle Zigbee) :
négociation de clé, commandes Matter, retours d'état, mesures, coupure et reconnexion, trames
corrompues ou fragmentées, endpoint Matter créé à chaud, API, recherche (annonces au format
TinyTuya), import `devices.json`, import cloud (signature comparée à celle de TinyTuya) et page
web, `toggle`. Le workflow **Build firmware** les lance
avant chaque compilation, sur le driver source puis sur le driver solidifié.

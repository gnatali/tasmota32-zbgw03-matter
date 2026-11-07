# Driver Tuya local : documentation technique

*English version: [tuya-local-dev.en.md](tuya-local-dev.en.md)*

Ce document décrit ce qui a été développé les 6 et 7 novembre 2026 sur la branche
`tuya-local-crypto` (PR #7) : solidification du driver dans le firmware, synchronisation avec
Matter, configuration depuis la passerelle (API, recherche, import des clés, page web), liens
directs avec Zigbee, et le banc de test qui couvre tout cela. La documentation d'utilisation
est dans [tuya-local.fr.md](tuya-local.fr.md) ; des exemples de commandes et d'événements dans
[tuya-local-examples.fr.md](tuya-local-examples.fr.md).

## Sommaire

1. [Architecture](#1-architecture)
2. [Solidification dans le firmware](#2-solidification-dans-le-firmware)
3. [Synchronisation avec Matter](#3-synchronisation-avec-matter)
4. [Fichier de configuration et API](#4-fichier-de-configuration-et-api)
5. [Recherche sur le réseau](#5-recherche-sur-le-réseau)
6. [Import du devices.json de tinytuya](#6-import-du-devicesjson-de-tinytuya)
7. [Import par le cloud Tuya](#7-import-par-le-cloud-tuya)
8. [Page web](#8-page-web)
9. [TuyaSend toggle et liens avec Zigbee](#9-tuyasend-toggle-et-liens-avec-zigbee)
10. [Banc de test](#10-banc-de-test)
11. [Mesures](#11-mesures)
12. [Limites et points ouverts](#12-limites-et-points-ouverts)
13. [Fichiers](#13-fichiers)

## 1. Architecture

Le driver est un seul fichier, `berry/tuya_local.be`, de neuf classes. Chacune est solidifiée
dans le firmware (une directive `#@ solidify:<Classe>,weak` par classe).

| Classe | Rôle | Présence en RAM |
|---|---|---|
| `TuyaCodec` | primitives du protocole : CRC-32, HMAC, AES-ECB, trames 6699, annonces UDP | fonctions statiques, aucune instance |
| `TuyaBinding` | liaison entre des DP Tuya et un endpoint Matter virtuel (conversions dans les deux sens, envoi `MtrUpdate`) | une par entrée `matter` |
| `TuyaNode` | appareil logique (Wi-Fi ou sous-appareil d'une passerelle) : dernier état `dps`, liaisons, relevés, table `codes` | un par appareil ou sous-appareil |
| `TuyaDevice` | connexion TCP et protocole 3.3 / 3.4 / 3.5 (hérite de `TuyaNode`) | un par appareil Wi-Fi |
| `TuyaScan` | recherche des appareils sur le réseau local | **créée à la demande**, libérée à la fin |
| `TuyaImport` | conversion des appareils de tinytuya ou du cloud en entrées de `tuya.json`, déduction des liaisons | fonctions statiques |
| `TuyaCloud` | requêtes signées vers l'API OpenAPI de Tuya | **créée à la demande**, libérée à la fin |
| `TuyaWeb` | page Configuration → Tuya local | fonctions statiques |
| `TuyaLocal` | le driver Tasmota : configuration, boucle, commandes, événements | une instance, créée par `autoexec.be` |

`TuyaLocal.every_50ms()` fait tourner les connexions, la recherche en cours, l'import cloud en
cours (une requête par seconde) et le renvoi vers Matter (toutes les 30 s).

## 2. Solidification dans le firmware

**Pourquoi** : chargé depuis le système de fichiers, le driver compilait son code en RAM, soit
environ 17 Ko sur les 40 Ko qu'il occupait avec 12 appareils. Solidifié, ce code est en flash.

**Comment** :

- `platformio_override.ini` : `custom_berry_solidify = ../berry/tuya_local.be` (chemin relatif
  au dépôt Tasmota, cloné dans `tasmota/` par le workflow).
- Le script de Tasmota `pio-tools/solidify-from-url.py` n'enregistrait dans `be_modtab.c` que
  la première classe d'un fichier. Le correctif `patches/berry-solidify-all-classes.patch`
  enregistre toutes les classes qui ont une directive `#@ solidify:` : sans lui, les classes
  qui s'appellent par leur nom global (`TuyaDevice`, `TuyaCodec`...) seraient introuvables.
- Option `weak` : les chaînes restent hors de la table globale ; le générateur `coc` de Tasmota
  parcourt `berry_custom/src/solidify` et crée leurs définitions.

**Contraintes**, vérifiées par le banc de test :

- **aucun code au premier niveau** hors des classes : la solidification exécute le fichier sans
  `tasmota`. Le driver est instancié par `autoexec.be` (`global.tuya_local = TuyaLocal()`),
  qui charge encore `tuya_local.be` si le firmware ne contient pas le driver ;
- **imports dans les méthodes** (`import string`, `json`, `crypto`, `webserver`...) : un import
  de premier niveau n'existe pas dans le firmware ;
- **classes en lecture seule** : une `static var` ne peut pas être écrite
  (`attribute_error ... cannot assign to static attribute`). La table CRC, autrefois calculée
  au premier appel, est devenue une table constante de 16 entrées (CRC par quartet, vérifiée
  contre `zlib.crc32` et la valeur de référence `0xCBF43926`) ;
- un `tuya_local.be` chargé par `load()` remplace le driver solidifié (ses classes deviennent
  des globales qui masquent les classes natives), ce qui permet d'essayer une version sans
  reflasher.

## 3. Synchronisation avec Matter

- `TuyaBinding.push(changed)` convertit les DP modifiés en attributs et envoie
  `MtrUpdate {"Name":"<ep>",...}`.
- Réponses de `MtrUpdate` (source de `Matter_zz_Device.be`) : l'état de l'endpoint
  (`{"MtrUpdate":{...}}`), ou `Done` pour un endpoint qui ne publie pas d'état (`v_fan`), sinon
  un message d'erreur (`Invalid Device`, `Invalid attribute '...'`...). Les deux premières sont
  des succès.
- Au premier refus, la liaison passe **en attente** (`pending`) et le refus est journalisé une
  seule fois. `TuyaLocal.sync_pending()` lui renvoie l'**état complet** toutes les 30 s
  (`SYNC_RETRY`), et toute nouvelle valeur de l'appareil aussi. Dès que l'endpoint accepte :
  `TUY: endpoint Matter '<ep>' disponible, etat envoye`.
- Côté Google Home, un nouvel endpoint reste **hors ligne jusqu'au `Restart 1`** de Tasmota (le
  contrôleur ne s'abonne aux nouveaux endpoints qu'à la reconnexion), quel que soit l'état
  envoyé par le driver.

## 4. Fichier de configuration et API

- `read_conf()` : `/tuya.json` absent ou vide donne une configuration vide ; un fichier invalide
  lève une erreur et n'est **jamais écrasé**.
- `write_conf()` : copie l'ancienne version dans `/tuya.json.bak`, écrit le JSON indenté, puis
  la configuration est rechargée (`load_config()`).
- `save_device(d, ref)` : ajoute ou remplace un appareil, désigné par `ref` (identifiant ou nom,
  sans casse) ou par son `id`. Une clé absente, vide ou `***` conserve la clé enregistrée.
  Refus d'un nom ou d'un identifiant déjà utilisé par un autre appareil.
- `load_config()` ignore les appareils `"enabled": false` et ceux sans `ip`, `key` ou `id`.

Commandes (toutes accessibles en console, HTTP `/cm?cmnd=` et MQTT `cmnd/<topic>/`) :

| Commande | Fonction | Réponse |
|---|---|---|
| `TuyaStatus [appareil]` | état des connexions et dernières valeurs | `{"TuyaStatus":{...}}` |
| `TuyaSend <appareil>,<dp ou code>,<valeur ou toggle>` | envoi d'une valeur | `Done` ou message d'erreur |
| `TuyaReload` | relecture de `tuya.json` | `Done` |
| `TuyaConfig [appareil]` | configuration, clés remplacées par `***` | `{"TuyaConfig":{...}}` |
| `TuyaAdd <json>` | ajout ou remplacement d'un appareil | `{"TuyaAdd":"<nom>"}` |
| `TuyaDel <appareil>` | suppression | `{"TuyaDel":"<nom>"}` |
| `TuyaScan [s]` | recherche (20 s, 60 au plus) | immédiate, puis événement `TuyaScan` |
| `TuyaImport [fichier] [all\|id,...]` | import du `devices.json` | `{"TuyaImport":{"Added":[...],"Updated":[...],"Skipped":[...]}}` |
| `TuyaCloud <json>` | import par le cloud | immédiate, puis événement `TuyaCloud` |
| `TuyaMatter` | création des endpoints Matter manquants | `{"TuyaMatter":{"Added":[...],"Restart":"..."}}` |

Les commandes ajoutées passent par `run_cmd()` : une erreur prévue (`tuya_error`) devient
`{"<commande>":{"Error":"<message>"}}`, une erreur inattendue est en plus journalisée.
Les opérations en arrière-plan (recherche, cloud) publient leur résultat par `report()` :
journal, `RESULT` (MQTT et règles) et message sur la page web.

## 5. Recherche sur le réseau

Reprise de `tinytuya scan` (`scanner.py`, `udp_helper.py` de TinyTuya 1.20) :

- écoute des ports UDP **6666** (3.1, en clair), **6667** (3.3, AES-ECB) et **7000** (3.5,
  trame 6699 en AES-GCM) ; clé fixe `md5("yGAdlopoPVldABfn")` (`TuyaCodec.UDP_KEY`) ;
- trame 55AA : en-tête de 16 octets, code retour de 4 octets, données, CRC et suffixe ; données
  en clair si elles commencent par `{`, sinon déchiffrées. Trame 6699 : en-tête de 18 octets
  (octets 4 à 17 en données authentifiées), IV de 12 octets, données, tag de 16 octets ; code
  retour retiré s'il précède `{` ; octets nuls de fin retirés (`TuyaCodec.decode_udp`) ;
- les appareils 3.5 ne s'annoncent qu'à la demande : diffusion toutes les 6 s vers
  `255.255.255.255:7000` d'une trame 6699 `REQ_DEVINFO` (commande `0x25`), contenant
  `{"from":"app","ip":"<adresse de la passerelle>"}` (Ethernet, sinon Wi-Fi). Notre propre
  demande, reçue sur le port 7000, est ignorée (champ `from`) ;
- résultat par identifiant (`gwId`) : `id`, `ip`, `version`, `product_key`. Il est publié en
  fin de recherche et gardé (`scan_result`) pour la page et les imports.

Garde mémoire : 15 Ko libres au moins pour lancer une recherche.

## 6. Import du devices.json de tinytuya

- **Lecture par morceaux** (`TuyaImport.each_object`) : le fichier est lu par blocs de 512
  octets, les objets du tableau sont repérés par un automate (profondeur d'accolades, chaînes,
  échappements) et analysés un par un. Un objet de plus de 8 Ko est ignoré (journal
  `objet JSON trop gros`). La taille du fichier n'est donc pas limitée par la RAM.
- **Sélection** : par défaut, les appareils trouvés par la dernière recherche ou déjà
  configurés, et les sous-appareils dont la passerelle l'est ; `all` : tous ; `id,id` : ceux-là.
- **Entrée créée** (`TuyaImport.entry`) : `name`, `id`, `key` (ou `local_key`), `ip` et
  `version` du fichier, sinon de la recherche, liaisons `matter`, relevés `sensors`, table
  `codes`. Sans clé : ignoré. Sans IP connue : `"enabled": false`. Sous-appareil (`"sub":true`) :
  `cid` = `node_id`, rattaché à sa passerelle (`parent` ou `gateway_id`).
- **Fusion** (`TuyaImport.merge`) : un appareil déjà configuré (même `id`) **garde ses
  liaisons** ; seules sa clé, son IP et sa version sont mises à jour, et seulement si l'import
  les connaît (correction : la version d'un appareil connu n'est plus remplacée par 3.3).
- **Déduction des liaisons** (`TuyaImport.auto`), d'après la catégorie Tuya et les codes de DP :

| Cas | Codes de DP | Liaison |
|---|---|---|
| ventilateur (`fs`, `fsd`, `fskg`, ou code de vitesse) | `switch` / `fan_switch` + `fan_speed` / `fan_speed_percent` entier | `fan` (plage de vitesse du mapping) ; vitesse en énumération : `relay` |
| … avec lumière | `light` / `switch_led` | `light0` « Lumière <nom> » |
| lumière | `switch_led` + `bright_value(_v2)` + `colour_data_v2` / `temp_value_v2` | `light3` / `light2` / `light1` / `light0` (plage de luminosité du mapping, `work_mode`) |
| prise avec mesures | un seul `switch` + `cur_power` (+ `cur_voltage`, `cur_current`) | `relay_power`, diviseurs 10^scale (et mA → A) |
| interrupteurs | `switch`, `switch_1` … `switch_8` | un `relay` par canal (« <nom> 1 », « <nom> 2 »...) |
| capteur | `va_temperature` / `temp_current`, `va_humidity` / `humidity_value` | `temp`, `humidity` (diviseur 10^scale) |
| compteur d'énergie (`zndb`, `dlq`) | DP entiers avec unité | `sensors` |

Les noms d'endpoint sont tronqués à 32 octets sans couper un caractère UTF-8.

## 7. Import par le cloud Tuya

Reprise de `tinytuya.Cloud` (`Cloud.py`) :

- hôtes par région : `eu` openapi.tuyaeu.com, `we` openapi-weaz.tuyaeu.com, `us`
  openapi.tuyaus.com, `ue` openapi-ueaz.tuyaus.com, `cn` openapi.tuyacn.com, `in`
  openapi.tuyain.com, `sg` openapi-sg.iotbing.com ;
- requêtes : `GET /v1.0/token?grant_type=1` (jeton), puis pour chaque appareil
  `GET /v1.0/devices/<id>` (nom, `local_key`, catégorie) et
  `GET /v1.1/devices/<id>/specifications` (`status` et `functions` → mapping des DP) ;
- signature : `HMAC-SHA256(secret, client_id + [access_token] + t + "GET\n" + sha256("") +
  "\n\n" + chemin)` en hexadécimal majuscule, `t` en millisecondes (heure NTP requise) ;
  en-têtes `client_id`, `sign`, `t`, `sign_method`, `mode`, et `access_token`, ou `secret` pour
  la demande de jeton (comme tinytuya). Le banc de test compare la signature à celle de
  `tinytuya.Cloud` ;
- **une requête par seconde** (chaque requête bloque le temps de la poignée de main TLS) ;
  **35 Ko libres** exigés avant chaque requête (le client HTTPS de Tasmota réserve un tampon de
  16 Ko, `HttpClientLight`) ;
- appareils : ceux passés dans `"devices"`, sinon ceux de la dernière recherche. Les
  sous-appareils ne sont pas traités. Les identifiants ne sont pas enregistrés.

## 8. Page web

- Enregistrement : `web_add_config_button()` (bouton **Tuya local** sur la page Configuration)
  et `web_add_handler()` (routes `GET` et `POST /tuya`). Le driver démarrant après le serveur
  web, Tasmota ne lui appelle pas `web_add_handler()` : le driver l'appelle lui-même, seulement
  si `webserver.state() > 0` (`webserver.on()` fait planter l'ESP32 si le serveur n'est pas
  démarré).
- `TuyaWeb.page()` : message de la dernière action, sections Appareils, Endpoints Matter,
  Recherche, Importer ; `?edit=<ref>` : édition JSON (clé remplacée par `***`).
- `TuyaWeb.post()` : actions `save`, `del`, `reload`, `scan`, `import`, `cloud`, `matter`, puis
  redirection vers `/tuya` (ou `/?rst=` pour redémarrer après la création d'endpoints).
- Endpoints Matter : `matter_missing()` compare les noms des liaisons à ceux de
  `matter_device.plugins_config` ; `matter_create()` appelle
  `matter_device.bridge_add_endpoint(<type v_...>, {"name": <ep>})` (API interne de Matter, celle
  de sa propre page de configuration).

## 9. TuyaSend toggle et liens avec Zigbee

`TuyaSend <appareil>,<dp>,toggle` inverse un DP booléen d'après le dernier état reçu
(`node.dps`) ; refus si cet état est inconnu ou n'est pas un booléen. Une règle Tasmota relie
ainsi un bouton Zigbee à un appareil Tuya sans Berry ni cloud (voir les exemples). Le message
d'état d'un appareil Tuya (`{"Tuya":{"Name":...,"Dps":{...}}}`, publié par
`tasmota.publish_result`) déclenche aussi les règles, ce qui permet le sens inverse.

## 10. Banc de test

`berry/test/run_tests.sh <dépôt Tasmota>` construit **deux interpréteurs** à partir du Berry de
Tasmota et de son BearSSL :

1. **driver source** : le harnais compile `tuya_local.be` en mode strict, comme `load()` ;
2. **driver solidifié** : `tuya_local.be` est solidifié comme au build (port Python
   `berry_port`, `solidify_all_python.be`), la table des chaînes est générée par `coc`, et les
   classes natives sont liées à l'interpréteur (`be_modtab.c` recompilé avec un `modules.h` qui
   les déclare), en lecture seule comme en flash.

Les mêmes scénarios sont joués sur les deux. Simulations (`harness.be`, `webserver.be`,
`crypto.be`) : `tasmota` (temps, règles, commandes, mémoire libre, adresses), `tcpclientasync`,
`udp`, `webclient` (réponses préparées par chemin), `webserver`, `matter_device`. Les faux
appareils (`fake_tuya.py`) et les annonces UDP (`udp_broadcast()`, vérifiées par
`decrypt_udp()`) sont construits avec TinyTuya.

| N° | Scénario |
|---|---|
| 1 | connexion, négociation de clé, état initial (6 appareils, 3.3 / 3.4 / 3.5, passerelle) ; réponse `Done` acceptée |
| 2 à 5 | Matter → ventilateur 3.5, ampoule CCT 3.3, projecteur RGB 3.4, passerelle Zigbee |
| 6 | relevés `SENSOR` et page d'accueil |
| 7 | `TuyaSend`, `TuyaStatus` |
| 8 à 11 | heartbeat et reconnexion, appareil muet, trame corrompue, trames fragmentées ou groupées |
| 12, 13 | endpoint Matter absent, puis créé après coup (renvoi de l'état complet) |
| 14 | API : `TuyaConfig` sans clés, `TuyaAdd` (clé conservée), `TuyaSend` par code, `TuyaDel`, `.bak` |
| 15 | recherche : annonces 3.1 / 3.3 / 3.5, demande 3.5, paquets ignorés, garde mémoire |
| 16 | import `devices.json` : sélection, types déduits, sous-appareil, objet trop gros, `all` |
| 17 | import cloud : signature identique à TinyTuya, clé et DP, erreur du cloud, garde mémoire |
| 18 | page web : liste, édition (clé masquée puis conservée), suppression, endpoints Matter, recherche |
| 19 | `TuyaSend ... toggle` |

Le workflow lance le banc avant la compilation ; il crée `/tuya.json`, `/tuya.json.bak` et
`/devices.json`, que le test écrit.

## 11. Mesures

**Firmware** (builds GitHub Actions) :

| Exécution | Contenu | Taille | Écart |
|---|---|---|---|
| 10 | driver chargé depuis le système de fichiers | 2 040 447 octets | |
| 11 | driver solidifié | 2 063 295 octets | +22,3 Ko |
| 12 | renvoi vers Matter | 2 064 191 octets | +0,9 Ko |
| 13 | API, recherche, imports, page web | 2 099 167 octets | +34,2 Ko |
| 14 | réponse `Done` | 2 099 215 octets | |
| 15 | `toggle` | 2 099 471 octets | |

RAM statique (DRAM) : 65 948 octets avant, 66 076 après (+128 octets en tout).

**Mémoire libre sur la passerelle** (`Heap` de `Status 4`) :

| Situation | Heap |
|---|---|
| driver chargé depuis le système de fichiers, 12 appareils | 34 Ko |
| driver solidifié, 12 appareils | 48 Ko |
| driver solidifié, 3 appareils, 5 endpoints Matter | 61 Ko |
| exécution 13, juste avant le démarrage du driver | 73 Ko |
| exécution 13, driver démarré, 3 appareils (relevés successifs) | 56 à 62 Ko |
| pendant une recherche / après `Br tasmota.gc()` | −2 Ko / retour à la normale |

Les endpoints Matter virtuels coûtent moins de 1 Ko pour quatre. Sur le banc de test (64 bits),
la configuration simplifiée ajoute 0,7 à 1,3 Ko au repos.

## 12. Limites et points ouverts

- **HTTPS vers le cloud Tuya** : testé seulement en simulation (signature conforme à
  TinyTuya) ; à valider sur la passerelle avec au moins 35 Ko libres.
- `bridge_add_endpoint()` est une API interne de Matter : à vérifier à chaque changement de
  `TASMOTA_REF`.
- La commande `TuyaCloud` est journalisée par la console web, secret compris : préférer la page.
- Non gérés à l'import : `temp_value` (ancien format 0 à 255), vitesse de ventilateur en
  énumération, `colour_data` (ancien format) ; sous-appareils par le cloud.
- La recherche ne traverse pas un routeur (diffusion UDP).
- Une trace Berry sans message d'erreur a été relevée 14 s après le démarrage du driver
  (origine inconnue).

## 13. Fichiers

| Fichier | Contenu |
|---|---|
| `berry/tuya_local.be` | le driver (9 classes) |
| `patches/berry-solidify-all-classes.patch` | enregistrement de toutes les classes solidifiées |
| `platformio_override.ini` | `custom_berry_solidify` |
| `berry/test/run_tests.sh` | construction des deux interpréteurs, solidification, scénarios |
| `berry/test/harness.be`, `webserver.be`, `crypto.be` | simulations de Tasmota |
| `berry/test/fake_tuya.py`, `test_tuya_local.py` | faux appareils, annonces UDP, 19 scénarios |
| `.github/workflows/build.yml` | fichiers écrits par les tests |
| `docs/tuya-local.fr.md` / `.en.md` | documentation d'utilisation |
| `docs/tuya-local-examples.fr.md` / `.en.md` | exemples de commandes et d'événements |
| `docs/tuya-local-suivi.fr.md` | suivi du chantier, mesures |

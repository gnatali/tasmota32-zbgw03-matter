# Suivi du chantier : appareils Tuya en local

*English version (reference): [tuya-local-tracking.en.md](tuya-local-tracking.en.md)*

Dernière mise à jour : **8 novembre 2026**. Branche `tuya-local-crypto`, PR #7 (non fusionnée).

## Objectif

Piloter depuis la ZB-GW03, **sans le cloud Tuya et sans flasher les appareils**, les appareils
Tuya Wi-Fi et les sous-appareils Zigbee de la passerelle Tuya, et les présenter à **Matter**
(Google Home). C'est l'équivalent de LocalTuya pour Home Assistant, mais sur la passerelle.

## État

| Étape | État |
|---|---|
| Crypto Berry : `USE_BERRY_CRYPTO_AES_CBC` + correctif `berry-aes-gcm-128-aad.patch` | ✅ compilé, en service sur la passerelle |
| Driver `berry/tuya_local.be` : protocoles 3.3 / 3.4 / 3.5, passerelle Tuya (`cid`) | ✅ **testé sur les vrais appareils** : 5 appareils Wi-Fi et 7 sous-appareils connectés, valeurs correctes |
| Banc de test (21 scénarios) dans le workflow | ✅ passe en local (source et solidifié) |
| **Configuration simplifiée** : page web `/tuya`, recherche UDP, import `devices.json` et cloud, types déduits des DP, API (`TuyaConfig`, `TuyaAdd`, `TuyaDel`, `TuyaScan`, `TuyaImport`, `TuyaCloud`, `TuyaMatter`) | ✅ banc de test ; ✅ build (exécution 13, 2050 Ko) ; ✅ recherche sur la passerelle (3 appareils) ; ⏳ import cloud sur la passerelle (correctif de l'exécution 16, pas encore flashé) |
| **Solidification du driver** (`custom_berry_solidify`, correctif `berry-solidify-all-classes.patch`) | ✅ banc de test : driver source **et** driver solidifié ; ✅ build du firmware (2015 Ko) ; ✅ sur la passerelle : **48 Ko libres avec les 12 appareils connectés** (34 Ko avant), le driver consomme ~23 Ko au lieu de ~40 |
| Documentation utilisateur `docs/tuya-local.{en,fr}.md` | ✅ |
| Chargement différé dans `autoexec.be` (plantage au démarrage) | ✅ corrigé et documenté |
| **Mémoire** avec les 12 appareils connectés : 34 Ko libres avec le driver chargé depuis le système de fichiers, **48 Ko** avec le driver solidifié | ✅ ~14 Ko de marge en plus |
| Endpoints Matter et essais dans Google Home | ✅ 5 endpoints créés (`Entrée-Porche`, `Ventilateur`, `Lumière ventilateur`, `Récepteur radio 1` et `4`), dans Google Home après `Restart 1` ; 61 Ko libres |
| Pergola 1 et 2 (projecteurs RGB) | ⏳ absentes du scan : IP et version inconnues, désactivées dans `tuya.json` |
| Migration des contrôleurs LED Zigbee Bureau et Salon sur la ZB-GW03 | ⏳ décidée, pas faite |

## Historique

1. **Recherche** : aucun équivalent de LocalTuya n'existe pour Tasmota. Le protocole est décrit par
   TinyTuya (`PROTOCOL.md`). Le Berry de Tasmota avait le TCP, MD5 et HMAC-SHA256, mais ni
   l'AES-ECB (`AES_CBC` existe, mais doit être activé à la compilation) ni l'AES-128-GCM avec
   AAD (`AES_GCM` n'acceptait que des clés de 32 octets, sans AAD).
2. **Scan** des appareils (`tinytuya scan`) : deux en 3.3, trois en 3.5. Il y a aussi 9
   appareils Zigbee sur la passerelle Tuya.
3. **Décision** : la passerelle Tuya garde ses sous-appareils, pilotés à travers elle. Seules
   les lumières Zigbee (contrôleurs LED Bureau et Salon) seront migrées sur la ZB-GW03.
4. **Crypto** : correctif `AES_GCM` (clés de 16 octets, 4ᵉ argument AAD optionnel), vérifié
   contre la bibliothèque `cryptography` (40 cas), puis option `AES_CBC`.
5. **Driver et banc de test**, puis PR #7. Le workflow (lancé à la main) passe : 12/12 tests,
   firmware de 1992 Ko.
6. **Sur la passerelle** : `load("tuya_local.be")` directement dans `autoexec.be` a fait
   planter l'ESP32 au démarrage. Après 4 plantages, la protection anti-boucle a démarré sans
   Berry (`Br` → `Unknown`, `/bc` introuvable, Matter absent) et a désactivé les règles.
   Correction : chargement 30 s après le démarrage, s'il reste au moins 60 Ko. Depuis, tout
   fonctionne.
7. **Solidification** (étape 1 ci-dessous) : le driver est intégré au firmware par
   `custom_berry_solidify = ../berry/tuya_local.be`. Ce qu'il a fallu changer :
   - le script de Tasmota (`pio-tools/solidify-from-url.py`) n'enregistrait dans
     `be_modtab.c` que la **première** classe d'un fichier : correctif
     `berry-solidify-all-classes.patch`, pour toutes les classes du driver ;
   - une classe solidifiée est en lecture seule : la table CRC, calculée au premier appel
     dans une `static var`, est remplacée par une table constante de 16 entrées (CRC par
     quartet, vérifiée contre `zlib.crc32` et la valeur de référence `0xCBF43926`) ;
   - plus de code au premier niveau : imports dans les méthodes, instanciation dans
     `autoexec.be` (`global.tuya_local = TuyaLocal()`), qui charge encore `tuya_local.be`
     si le firmware ne contient pas le driver ;
   - le banc de test solidifie le driver comme le build (`berry_port`, `coc`) et rejoue les
     12 scénarios sur les classes natives. Le C généré fait ~206 Ko de source.
   - **Build** (exécution 11, commit `df4ed7d`) : firmware de 2 063 295 octets (2015 Ko,
     +22,3 Ko), soit la hausse de `.rodata` (676 464 → 699 280 octets, +22,3 Ko). La RAM
     statique ne bouge pas (DRAM 65 948 → 65 980 octets, +32). Il reste ~865 Ko en flash.

8. **Configuration simplifiée** (7 novembre), d'après une évaluation chiffrée faite au
   préalable (flash 25 à 35 Ko, RAM permanente 1 à 2 Ko, pic de 22 à 28 Ko pour l'import cloud) :
   - **API** : `TuyaConfig` (sans les clés), `TuyaAdd` (clé `***` conservée), `TuyaDel`,
     `TuyaStatus <appareil>`, `TuyaSend` par code de DP ; sauvegarde `/tuya.json.bak` ;
   - **recherche** (`TuyaScan`, classe `TuyaScan` créée à la demande) : annonces UDP 6666 /
     6667 / 7000 avec la clé fixe `md5("yGAdlopoPVldABfn")`, demande `REQ_DEVINFO` (0x25) pour
     les 3.5, comme `tinytuya scan` ;
   - **import** (`TuyaImport`) du `devices.json` de tinytuya, lu par morceaux de 512 octets
     (objets de plus de 8 Ko ignorés) ; liaisons Matter déduites de la catégorie et des codes de
     DP ; sous-appareils rattachés à leur passerelle ;
   - **cloud** (`TuyaCloud`, classe créée à la demande) : signature OpenAPI comme tinytuya, une
     requête par seconde, refus sous 35 Ko libres (le client HTTPS réserve 16 Ko) ;
   - **page web** `/tuya` (classe `TuyaWeb`, fonctions statiques) : liste, édition JSON,
     recherche, imports, création des endpoints Matter puis redémarrage (`bridge_add_endpoint`,
     API interne de Matter, à surveiller à chaque `TASMOTA_REF`).
   Banc de test : 18 scénarios, 18/18 en source et en solidifié. Mesure sur le banc (64 bits,
   à diviser par environ 2 pour l'ESP32) : +0,7 à +1,3 Ko au repos, +4,5 Ko pendant une
   recherche qui trouve 10 appareils. Driver : ~1700 lignes de code, C solidifié de 507 Ko.
   **Build** (exécution 13, commit `df91caf`) : firmware de 2 099 167 octets (2050 Ko,
   **+34,2 Ko**, dans l'estimation de 25 à 35 Ko), `.rodata` 735 056 octets ; RAM statique
   +96 octets (DRAM 65 980 → 66 076). Il reste ~830 Ko en flash.

9. **Liens directs Zigbee → Tuya** (7 novembre) : `TuyaSend <appareil>,<dp>,toggle` inverse
   un DP booléen d'après l'état connu (scénario 19). Règle proposée pour le bouton SNZB-01P
   `0x922D` (déjà relié au bouton virtuel Matter « Perron » par `Rule1`) : `Rule2`, voir
   `docs/tuya-local.fr.md`. La recherche a trouvé les 3 appareils sur la passerelle.
   Build : exécution 15 (commit `6b51e4a`), 19/19 dans les deux modes, firmware de
   2 099 471 octets ; à flasher.

10. **Documentation** (7 novembre) : `docs/tuya-local-dev.fr.md` / `.en.md` (documentation
    technique de la session : architecture, solidification, Matter, API, recherche, imports, page
    web, banc de test, mesures) et `docs/tuya-local-examples.fr.md` / `.en.md` (commandes,
    réponses, événements, règles, scripts Berry), liés depuis les README et la doc d'utilisation,
    elle-même traduite en anglais (`docs/tuya-local.en.md`).

11. **Import cloud : `{"Error":"cloud Tuya : reponse invalide"}`** (7 novembre, sur la
    passerelle) : toute réponse de l'OpenAPI se termine par `"t":<heure en ms>` (13 chiffres),
    qui dépasse les entiers 32 bits de Berry ; `json.load` renvoie alors `nil` pour tout le
    document, dès la demande de jeton. Le banc de test ne le voyait pas (fausses réponses sans
    `"t"`). Correctif : `TuyaCloud.quote_big` met entre guillemets les entiers de plus de
    9 chiffres avant `json.load`. Vérifié dans le conteneur avec le compte de Guillaume :
    signature acceptée, 33 vraies réponses lues (16 appareils, 16 clés, 150 DP ; la passerelle
    Tuya répond `not support this device` aux spécifications, ce qui est normal). Scénario 17
    complété (il échoue sans le correctif). Build : exécution 16 (commit `1171ed1`), 19/19 dans
    les deux modes, firmware de 2 099 967 octets (+0,5 Ko) ; à flasher.

12. **Identifiants du cloud enregistrables** (8 novembre) : case « enregistrer les
    identifiants » sur la page, `"save":true|false` et `TuyaCloud` sans argument pour la
    commande. Fichier à part, `/tuya_cloud.json`, pour que `TuyaConfig`, la page d'édition et
    `tuya.json.bak` ne les exposent jamais ; secret jamais réaffiché ; case décochée = fichier
    vidé. Scénario 20 (20/20 dans les deux modes). **Pas de build** à la demande de Guillaume :
    il viendra avec la prochaine modification.

13. **Page web au format Tasmota, interface en anglais** (8 novembre) : sur un écran
    d'ordinateur, la page s'étalait sur toute la largeur (formulaire du cloud : liste et champs
    côte à côte, longs paragraphes), contrairement aux pages de Tasmota (Matter). Désormais
    340 px comme Tasmota (paragraphes de 320 px, un champ par bloc avec son libellé, en-têtes de
    tableau en petit), vérifié par capture avec le CSS de Tasmota. Pictogrammes HTML pour les
    actions (🔌 bouton, 📝 modifier, 🔥 supprimer, 💾, ➕, 🔄, 🔍, 📥, ☁️ ; états 🟢 🔴 ⚪ ⚠ ;
    recherche ✅/🆕). Page, réponses, erreurs et journal **en anglais** ; noms d'endpoints
    déduits à l'import inchangés (français). Tests et docs FR/EN adaptés (20/20 dans les deux
    modes). **Pas de build** : à lancer avec la prochaine modification. Le `autoexec.be` de la
    doc journalise aussi en anglais (celui de la passerelle reste valable tel quel).

14. **Règle de langue** (8 novembre) : commentaires du code, documentation, messages de commit,
    `CLAUDE.md` et `.claude/rules/` sont désormais **en anglais** ; la documentation
    utilisateur est rédigée en anglais (référence) et traduite en français (`README.fr.md`,
    `docs/*.fr.md`). Tous les commentaires du driver, le banc de test, le workflow, la
    configuration de compilation et les en-têtes des correctifs ont été traduits ; ce suivi
    est devenu `tuya-local-tracking.fr.md`, traduction de `tuya-local-tracking.en.md`. Modules
    de règles renommés : `project.md`, `berry-pitfalls.md`. Aucun changement fonctionnel
    (20/20 dans les deux modes) ; **pas de build**.

15. **Liste des endpoints Matter avec cases à cocher** (8 novembre) : sur la passerelle, la
    section listait les endpoints manquants en texte, et les créait tous d'un coup. C'est
    maintenant un tableau comme la liste des appareils : une ligne par liaison, ✅ et le numéro
    d'endpoint s'il existe, une case à cocher s'il manque (case d'en-tête pour tout cocher) ;
    **➕ Create and restart** ne crée que les endpoints cochés (aucun coché : refus).
    `TuyaMatter [nom,nom]` fait de même par commande. Scénario 18 complété (20/20 dans les deux
    modes), page vérifiée à 340 px. **Pas de build**.
    **À vérifier** : la capture de Guillaume listait comme manquants des endpoints qui
    existaient déjà dans Configuration → Matter (`Entrée-Porche`, `Ventilateur`, `Récepteur
    radio 1` à `4`...) : la nouvelle liste affiche le numéro de chaque endpoint trouvé, ce qui
    montrera si le driver lit correctement la configuration de Matter sur la passerelle.

16. **Sans Matter : pas de `MtrUpdate`** (8 novembre) : la détection de Matter se fait à
    l'exécution (le driver est le même dans tous les firmwares). Sans la globale
    `matter_device` (firmware compilé sans Matter, ou Matter désactivé), `TuyaBinding.push()`
    n'envoie plus rien et ne met jamais une liaison en attente : avant, chaque liaison était
    refusée (commande « Unknown ») et renvoyée toutes les 30 s pour rien. Scénario 21 (21/21
    dans les deux modes ; il échoue sans le contrôle). Build : exécution 17, qui apporte aussi
    les entrées 12, 13 et 15 sur la passerelle.

## Mesures sur la passerelle

| Situation | `Heap` (`Status 4`) |
|---|---|
| Après mise à jour du firmware, avant le driver | 67 Ko |
| 30 s après le démarrage, juste avant de charger le driver | 74 Ko |
| Driver chargé, 12 appareils connectés, aucun endpoint Matter Tuya | **34 Ko** |
| **Driver solidifié** (firmware 2015 Ko, 6 novembre) : juste avant de démarrer le driver | 71 Ko |
| **Driver solidifié** : driver démarré, 3 appareils connectés | 61 Ko |
| **Driver solidifié** : driver démarré, **12 appareils connectés** (endpoint Matter `Entrée-Porche` créé) | **48 Ko** |
| Périmètre réduit (3 appareils), endpoint `Entrée-Porche` seul, 7 novembre | 62 Ko |
| + `Ventilateur` (v.Fan), après `Restart 1` | 58 Ko |
| + `Lumière ventilateur` (v.Light 0 OnOff), après `Restart 1` | 61 Ko |
| + `Récepteur radio 1` et `Récepteur radio 4` (v.Relay), après `Restart 1` : **5 endpoints** | **61 Ko** |
| Firmware de l'exécution 13 (page web, recherche, import), driver démarré, sans recherche | **55 Ko** |
| … juste après une recherche | 53 Ko |
| … après une recherche puis `Br tasmota.gc()` | 55 Ko |
| Exécution 13, juste avant le démarrage du driver (`autoexec.be`) | 73 Ko |
| … driver démarré, 3 appareils connectés, relevés à 5, 10 et 12 min (`STATE`, `Status 4`) | 56, 62, 60 Ko |

Avec les 12 appareils connectés, le driver consommait environ **40 Ko** chargé depuis le
système de fichiers (74 − 34 : code compilé en RAM, état des appareils, tampons), et environ
**23 Ko** solidifié (71 − 48 : état et tampons seulement). La solidification a donc retiré
**~17 Ko** de code de la RAM ; il reste **48 Ko libres au lieu de 34** (+14 Ko, le heap de
départ étant 3 Ko plus bas : 71 contre 74 Ko). L'état seul coûte ~23 Ko pour 12 appareils,
soit ~2 Ko par appareil en moyenne : il croît avec le nombre d'appareils connectés et de DP
reçus (pince : 22 DP, passerelle : 7 sous-appareils). Avec 3 appareils, 10 Ko (71 → 61).
Les 48 Ko incluent l'endpoint Matter `Entrée-Porche`. Il n'y a pas eu de mesure après
`Br tasmota.gc()`.

**Firmware de l'exécution 13** : la recherche coûte ~2 Ko le temps qu'elle dure, entièrement
rendus après `Br tasmota.gc()` (pas de fuite). Au repos, le heap **varie de 56 à 62 Ko**
d'un relevé à l'autre ; avec 73 Ko juste avant le driver, celui-ci consomme **11 à 17 Ko**
(10 Ko avec l'exécution 12, mesure unique). Le surcoût est donc de l'ordre du bruit de mesure,
cohérent avec le banc de test (+0,7 Ko sur 64 bits). Le heap de Berry est de 51 Ko (`STATE`).

**Coût des endpoints Matter** : de 62 Ko (1 endpoint) à 61 Ko (5 endpoints), soit **~1 Ko pour
4 endpoints**, dans le bruit de mesure (le 58 Ko intermédiaire en fait partie : le heap varie
de quelques Ko d'un relevé à l'autre). La marge de ~60 Ko est donc confortable.

**Répartition sur le banc de test** (driver solidifié, interpréteur 64 bits : sur l'ESP32,
les objets Berry font à peu près la moitié) : driver sans appareil ~3,7 Ko ; premier appareil
~8 Ko (dont le module `crypto` de test) ; chaque nœud de plus ~2,6 Ko (état `dps`, configuration
gardée en map, tampons `rx`/`tx`, objets de connexion). Stable sur 3 min de fonctionnement :
pas de fuite.

**Réécrire le driver en C ?** Étudié le 6 novembre, écarté pour l'instant. Le gain se limiterait
à l'état Berry des appareils (de l'ordre de 1 Ko par appareil sur l'ESP32, à confirmer) : les
connexions TCP coûtent autant en C, et les endpoints Matter (Berry) ne changent pas. Coûts : un
gros correctif de Tasmota à maintenir à chaque `TASMOTA_REF`, le banc de test à réécrire, et
une erreur en C fait planter l'ESP32 (boucle de redémarrage, Matter désactivé). D'abord :
réduire l'état Berry (étape 3) et mesurer le coût des endpoints Matter.

## Inventaire (sans clés ni identifiants : voir `tuya.json` sur la passerelle)

**Périmètre retenu (7 novembre)** : seuls le Ventilateur, le Récepteur radio et Entrée-Porche
sont actifs dans `tuya.json`, plus Pergola 1 et 2 désactivées (`"enabled": false`, IP
inconnue, version 3.3 supposée). La pince et la passerelle Tuya (avec ses sous-appareils) ne
sont **pas** dans `tuya.json` : hors périmètre. Soit **7 endpoints Matter** (9 avec les
Pergola), au lieu de 16. Avec 3 appareils connectés, le driver consomme ~10 Ko (71 → 61 Ko).

**Appareils Wi-Fi**

| Appareil | Protocole | Rôle dans `tuya.json` |
|---|---|---|
| Ventilateur | 3.5 | `fan` (DP 60/62, vitesses 1-6) + `light0` (DP 20) |
| Récepteur radio (4 canaux 433 MHz) | 3.5 | 4 × `relay` (DP 1 à 4) |
| Entrée-Porche (ampoule LSC CCT) | 3.3 | `light2` (DP 20/21/22/23) |
| A:Eau B:Chfg C:Cuisine (pince 3 circuits) | 3.5 | hors périmètre (pas dans `tuya.json`) |
| Gateway (passerelle Zigbee Tuya) | 3.3 | hors périmètre (pas dans `tuya.json`), avec ses sous-appareils |
| Pergola 1, Pergola 2 (projecteurs LSC RGB) | ? | `light3` (DP 20/21/22/24), `"enabled": false` |

**Sous-appareils Zigbee de la passerelle Tuya** (hors périmètre) : luminaires terrasse, Prise Lisseur et Relais
zigbee Cuisine (`relay_power`, DP 1/18/19/20) ; Interrupteur Terrasse et Chauffage
(`relay`) ; Temperature SdB (`temp` DP 1 et `humidity` DP 2, diviseur 10) ; Capteur de
température et d'humidité (`temp` DP 103 et `humidity` DP 101, diviseur 100).

**À migrer sur la ZB-GW03** : contrôleurs LED Bureau et Salon (E2-ZR), qui passeront en
endpoints Matter `z_light2` ou `z_light1`.

## Prochaines étapes (par priorité)

1. ~~**Solidifier le driver**~~ : fait et mesuré, 48 Ko libres avec les 12 appareils au lieu
   de 34 (voir les mesures). Le seuil de 60 Ko d'`autoexec.be` reste adapté (71 Ko avant le
   démarrage du driver, ~23 Ko consommés ensuite).
2. **Matter** : créer les endpoints un par un, avec **exactement** le nom de `ep` (accents
   compris), et tester les deux sens avec Google Home en relevant `Heap` après chacun :
   - ✅ `Entrée-Porche` : v.Light 2 CT ;
   - ✅ `Ventilateur` : v.Fan ; ✅ `Lumière ventilateur` : v.Light 0 OnOff ;
   - ✅ `Récepteur radio 1` et `Récepteur radio 4` : v.Relay. Les canaux 2 et 3 n'ont pas
     d'endpoint : les retirer de `tuya.json` s'ils ne servent pas (sinon, le driver tente de
     les mettre à jour toutes les 30 s, sans effet).
   **`Restart 1` obligatoire** après la création : sans lui, Google Home affiche les nouveaux
   appareils hors ligne. Reste à tester les deux sens (Google Home → appareil, et appareil
   → Google Home : bouton, Smart Life, télécommande) pour chaque endpoint.
3. **Réduire la RAM du driver** si les endpoints Matter ne laissent pas assez de marge (peu
   probable avec 3 appareils, ~10 Ko) :
   - ne garder dans `dps` que les DP utilisés par une liaison ou un capteur (la pince en
     envoie 22, les prises 11) ;
   - limiter `publish_result` (un message MQTT par changement, la pince en envoie souvent).
4. **Valider la configuration simplifiée** sur la passerelle (après flash) : page
   Configuration → Tuya Local, recherche (les 3 appareils doivent apparaître), `Heap` pendant
   et après, import du `devices.json` (puis import cloud, qui exerce le HTTPS vers Tuya : à
   tester avec au moins 35 Ko libres, avec le correctif de l'exécution 16 ou plus récent),
   création des endpoints Matter depuis la page, identifiants du cloud enregistrés, mise en
   page sur un écran d'ordinateur.
5. **Pergola 1 et 2** : les allumer, lancer la recherche de la page Tuya Local (ou
   `tinytuya scan`), renseigner `ip` et `version`, puis retirer `"enabled": false`.
6. **Migrer Bureau et Salon** sur la ZB-GW03 (procédure dans `docs/tuya-local.fr.md`).
7. **Fusionner la PR #7** une fois Matter validé, puis créer un tag `v*` pour publier la
   release.

## À vérifier côté passerelle

- **`MtrUpdate` répond `Done`** pour un endpoint qui ne publie pas d'état (`v_fan`) : le driver
  le prenait pour un refus (`TUY: endpoint Matter 'Ventilateur' : Done (nouvel essai toutes les
  30 s)`, journal de l'époque, désormais en anglais) et renvoyait l'état du ventilateur toutes les 30 s. Corrigé (réponses de
  `Matter_zz_Device.MtrUpdate` : l'état, ou `Done`, sinon un message d'erreur), scénario 1
  complété. Build : exécution 14 (commit `b8b2789`), 18/18 dans les deux modes, firmware de
  2 099 215 octets ; à flasher.
- **Trace Berry** relevée 14 s après le démarrage du driver (`stack traceback: <native>: in
  native function`, `BRY: stack[2] = type='function' ()`), sans la ligne d'erreur qui la
  précède : origine inconnue (driver, Matter ou autre). À relever en entier si elle revient.
- La passerelle est connectée en **Wi-Fi** (192.168.100.13), sur le même réseau que les
  appareils : la recherche s'en sert (adresse Wi-Fi si l'Ethernet n'en a pas).

- **Premier endpoint Matter (`Entrée-Porche`, v.Light 2 CT)** : créé, il est resté « non
  connecté » dans Google Home jusqu'à un `MtrUpdate {"Name":"Entrée-Porche","Power":1}` fait à
  la main ; depuis, tout fonctionne, y compris après `Restart 1`. Première hypothèse : le driver
  n'envoie à Matter que les **changements** d'état. S'il a reçu l'état de l'ampoule avant la
  création de l'endpoint, son `MtrUpdate` a échoué (`Invalid Device`) et n'a jamais été
  renvoyé : l'endpoint gardait ses valeurs par défaut. Correctif envisagé : renvoyer l'état
  complet d'une liaison tant que son `MtrUpdate` échoue (toutes les 30 s), pour qu'un endpoint
  créé à chaud reçoive son état sans redémarrage. **Fait** : `TuyaBinding.push()` met la
  liaison en attente au premier refus (signalé une seule fois), `TuyaLocal.sync_pending()` lui
  renvoie l'état complet toutes les 30 s, et toute mise à jour de l'appareil le renvoie aussi.
  Scénario 13 du banc de test (il échoue sur l'ancien driver). Build : exécution 12, firmware
  de 2 064 191 octets (+0,9 Ko). **Flashé le 7 novembre** : le premier flash a échoué (passerelle
  restée en safeboot), le second a fonctionné.
  **Hypothèse infirmée le 7 novembre** : avec ce firmware, les endpoints suivants apparaissent
  dans Google Home mais restent **hors ligne jusqu'au `Restart 1` de Tasmota**, alors que le
  driver leur envoie bien leur état. La vraie cause est côté Matter : Google Home ne s'abonne
  aux nouveaux endpoints qu'à la reconnexion. Pour `Entrée-Porche`, c'est donc sans doute un
  redémarrage, et non le `MtrUpdate` manuel, qui a tout débloqué. Conclusion : **`Restart 1`
  après la création des endpoints, toujours** (une seule fois pour plusieurs). Le renvoi
  d'état reste en place : sans effet visible, mais il évite qu'un endpoint garde des valeurs
  par défaut si Matter le crée après le driver.

- `Rule1` : la protection anti-boucle a désactivé les règles. Vérifier que `Rule1 1` a été
  refait (bouton Zigbee « Perron » dans Google Home).
- **Flash resté en safeboot** (7 novembre, exécution 12) : refaire le flash depuis la page
  safeboot a suffi, avec le `.bin` décompressé de l'artefact. Tasmota ne passe de lui-même en
  safeboot qu'après 10 redémarrages de suite dans les 10 premières secondes : le driver, démarré
  à 30 s, ne peut pas en être la cause.
- La cause exacte du plantage n'a pas été relevée (`Status 12` non collecté). Le chargement
  différé suffit, mais si un plantage revient, `Status 12` est la première chose à demander.

## Fichiers hors dépôt

| Fichier | Où | Contenu |
|---|---|---|
| `devices.json`, `snapshot.json` | PC de Guillaume (sortie de `tinytuya wizard` / `scan`) | clés locales, identifiants, IP, versions |
| `/tuya.json` | système de fichiers de la passerelle | configuration réelle, **avec les clés** |
| `/tuya_cloud.json` | système de fichiers de la passerelle | identifiants du cloud Tuya, s'ils ont été enregistrés depuis la page |
| `/autoexec.be` | système de fichiers de la passerelle | démarrage différé du driver (`/tuya_local.be` n'est plus nécessaire avec le driver solidifié) |

Pour reprendre le développement, demander à Guillaume les fichiers dont la tâche a besoin.
Ne jamais les committer.

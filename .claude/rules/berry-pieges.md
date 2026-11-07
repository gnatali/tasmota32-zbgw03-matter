---
paths:
  - "berry/**"
  - "**/*.be"
---
# Pièges connus (Berry sous Tasmota)

- Tasmota compile en **mode strict** (`comp_set_strict`) : dans une fonction ou un bloc, une
  affectation à un nom non déclaré est une erreur (`strict: no global 'x', did you mean 'var x'?`).
  Déclarer avec `var`, et créer une globale depuis une fonction avec `import global` puis
  `global.x = ...`. Au premier niveau du fichier chargé, `x = ...` reste permis et crée une
  globale. Le banc de test compile le driver source en mode strict.
- Entiers sur **32 bits** et flottants en **simple précision** : un compteur d'énergie
  divisé en flottant perd des décimales. Le driver formate les mesures en décimal exact à
  partir de l'entier (`TuyaLocal.scaled`). `json.load` renvoie **`nil` pour tout le
  document** dès qu'un entier dépasse 2 147 483 647 (ex. `"t"` en ms des réponses du cloud
  Tuya) : `TuyaCloud.quote_big` les met entre guillemets avant. Le banc de test a la même limite.
- `bytes .. bytes` **ajoute en place** et modifie l'opérande de gauche ; `+` crée un nouvel
  objet.
- Dans une f-string, pas d'opérateur `!=` ou `=` entre accolades (`{x=}` sert au débogage) :
  calculer la valeur dans une variable d'abord.
- `crypto.AES_GCM(cle, iv [, aad])` : clé de 16 ou 32 octets **grâce au correctif** de ce
  dépôt ; un seul `encrypt` ou `decrypt` par instance dans le module de test.
- `tcpclientasync.connected()` renvoie `nil` pendant la connexion, puis `true` ou `false`.
- **Driver solidifié** (`custom_berry_solidify`, classes en flash) :
  - aucun code au premier niveau hors des classes : la solidification exécute le fichier
    (sans `tasmota`), et c'est `autoexec.be` qui instancie le driver (`global.tuya_local = TuyaLocal()`) ;
  - `import string` / `json` / `crypto` **dans chaque méthode** qui s'en sert : un import de
    premier niveau n'existe pas dans le firmware ;
  - une classe solidifiée est **en lecture seule** : pas d'écriture dans une `static var`
    (`attribute_error ... cannot assign to static attribute`), constantes seulement ;
  - une directive `#@ solidify:Classe,weak` par classe (`weak` : chaînes hors table globale).
    Le script de Tasmota n'enregistrait que la première : correctif
    `patches/berry-solidify-all-classes.patch`.
- `webserver.on()` **fait planter l'ESP32** si le serveur web n'est pas encore démarré : le
  driver ne l'appelle lui-même que si `webserver.state() > 0` (Tasmota n'appelle pas
  `web_add_handler()` pour un driver ajouté après le démarrage du serveur).
- Fichier plus gros que la RAM libre (`devices.json` de tinytuya) : le lire par morceaux
  (`readbytes(512)`, `TuyaImport.each_object`), jamais `read()` d'un bloc.
- **Ne jamais démarrer le driver directement dans `autoexec.be`** : sans PSRAM, le charger
  pendant le démarrage de Zigbee et Matter fait planter l'ESP32. Après 4 plantages rapides,
  la protection anti-boucle démarre **sans Berry, donc sans Matter**, et **désactive toutes
  les règles**. Démarrer 30 s après le démarrage (voir `docs/tuya-local.fr.md`).
  `SetOption153 1` désactive `autoexec.be`.

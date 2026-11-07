# CLAUDE.md : passerelle ZB-GW03 (Tasmota, Zigbee, Ethernet, Matter, Tuya en local)

Firmware Tasmota de la passerelle eWeLink ZB-GW03 (Zigbee, Ethernet, Matter, appareils Tuya en local).

## 1. Règle de taille (permanente)

* **Ce fichier ne dépasse jamais 150 lignes.** Il ne contient que des directives courtes et
  l'index des modules : ni détails, ni tutoriels, ni documentation volumineuse.
* Si un ajout risque de dépasser la limite : **s'arrêter**, créer un module dans
  `.claude/rules/` et ne mettre ici qu'une ligne d'index qui pointe vers lui.
* Cette règle ne change que sur demande explicite de Guillaume.

## 2. Modules `.claude/rules/` (chargés par Claude Code)

* Les instructions détaillées vont dans un module de `.claude/rules/`, un sujet par fichier.
* Claude Code charge ces modules lui-même :
  * un module **sans** en-tête `paths:` est chargé à chaque session (ex. `projet.md`) ;
  * un module **avec** un en-tête `paths:` (motifs glob) n'est chargé que lorsqu'un fichier
    correspondant est lu ou modifié. Tout nouveau module spécialisé en a un.
* Ne pas utiliser d'import `@chemin` ici : il charge le fichier dès le démarrage. L'index
  ci-dessous utilise de simples liens Markdown.

## 3. Index des modules

* [`projet.md`](.claude/rules/projet.md) : contexte, matériel (pas de PSRAM, RAM critique), structure du dépôt, chantier en cours.
* [`build.md`](.claude/rules/build.md) : build GitHub Actions, lancement manuel, artefacts, correctifs.
* [`tests-tuya.md`](.claude/rules/tests-tuya.md) : banc de test du driver Tuya.
* [`berry-pieges.md`](.claude/rules/berry-pieges.md) : pièges de Berry sous Tasmota, driver solidifié, démarrage différé.
* [`secrets.md`](.claude/rules/secrets.md) : clés et identifiants Tuya hors du dépôt.

Voir aussi : suivi du chantier Tuya dans [`docs/tuya-local-suivi.fr.md`](docs/tuya-local-suivi.fr.md).

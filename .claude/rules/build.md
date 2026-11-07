---
paths:
  - "platformio_override.ini"
  - "user_config_override.h"
  - "patches/**"
  - ".github/**"
---
# Build du firmware

- Uniquement sur GitHub Actions, **pas en local** (toolchain lourde). Déclencheurs : tag `v*`
  (crée aussi la release) et lancement manuel. **Une PR ne déclenche rien** : lancer le build
  sur une branche (workflow `build.yml`, `ref=<branche>`) :
  - en session Claude Code web : `gh` n'y sert qu'à la recherche, passer par les outils MCP
    GitHub (`actions_run_trigger` pour le build, `pull_request_read` pour les PR,
    `actions_list` / `get_job_logs` pour suivre l'exécution) ;
  - en local : `gh api -X POST repos/gnatali/tasmota32-zbgw03-matter/actions/workflows/build.yml/dispatches -f ref=<branche>`
    (API REST : la GraphQL n'est pas disponible depuis Claude Code).
- Le firmware est dans l'artefact `firmware` de l'exécution (`tasmota32-zbgw03-matter.bin`
  pour une mise à jour, `.factory.bin` pour un premier flash).
- Avant d'ajouter un correctif : vérifier qu'il s'applique sur `TASMOTA_REF` **avec les
  correctifs existants** (`git apply --check`), et commencer le fichier par un en-tête en
  commentaire qui explique pourquoi.

---
paths:
  - "berry/**"
  - "docs/**"
  - "**/tuya*.json"
---
# Secrets

Les clés locales Tuya (`key`), les identifiants (`id`, `node_id`/`cid`) et le vrai
`tuya.json` **ne vont jamais dans le dépôt** (`.gitignore` couvre `tuya.json`). Ils restent sur
le PC de Guillaume (`devices.json` et `snapshot.json` de TinyTuya) et sur la passerelle
(`/tuya.json`). Avant chaque commit qui touche `berry/` ou `docs/`, vérifier qu'aucune clé ni
aucun identifiant réel n'y figure. Les tests utilisent des valeurs fictives.

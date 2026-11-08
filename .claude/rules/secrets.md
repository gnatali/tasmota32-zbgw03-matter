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
(`/tuya.json`). De même pour l'Access ID et l'Access Secret du cloud Tuya (`/tuya_cloud.json`
sur la passerelle, couvert par `.gitignore`). Avant chaque commit qui touche `berry/` ou
`docs/`, vérifier qu'aucune clé ni aucun identifiant réel n'y figure. Les tests utilisent des valeurs fictives.

---
paths:
  - "berry/**"
  - "docs/**"
  - "**/tuya*.json"
---
# Secrets

Tuya local keys (`key`), ids (`id`, `node_id`/`cid`) and the real `tuya.json` **never go into
the repository** (`.gitignore` covers `tuya.json`). They stay on Guillaume's PC (TinyTuya's
`devices.json` and `snapshot.json`) and on the gateway (`/tuya.json`). The same goes for the
Tuya cloud Access ID and Access Secret (`/tuya_cloud.json` on the gateway, covered by
`.gitignore`). Before every commit touching `berry/` or `docs/`, check that no real key or id
is in it. Tests use fake values.

---
paths:
  - "**"
---
# Projet : contexte, matériel, structure du dépôt

Firmware Tasmota maison pour la passerelle **eWeLink ZB-GW03** de Guillaume : Zigbee (EFR32 en
EZSP), Ethernet et **Matter**, plus un driver Berry qui pilote les appareils **Tuya en local**.
Échanges, commentaires, commits et documentation **en français**. Les README existent en
français et en anglais : toute modification de l'un se reporte dans l'autre.

**Chantier en cours** : appareils Tuya en local, branche `tuya-local-crypto`, PR #7. L'état,
les mesures faites sur la passerelle et les prochaines étapes sont dans
[docs/tuya-local-suivi.fr.md](../../docs/tuya-local-suivi.fr.md) : le lire avant de reprendre.

## Matériel (contraintes qui pèsent sur chaque choix)

- ESP32-D0WD, flash de 4 Mo, **pas de PSRAM**. Partitions : application 2880 Ko, système de
  fichiers 320 Ko (`esp32_partition_app2880k_fs320k.csv`). Firmware actuel : ~2015 Ko avec le
  driver Tuya solidifié, il reste ~865 Ko en flash.
- **La RAM est la ressource critique** : ~67 Ko libres avec Zigbee + Matter juste après le
  démarrage, ~71-74 Ko au bout de 30 s, **~48 Ko** avec en plus le driver Tuya solidifié et
  ses 12 appareils connectés (le driver consomme ~23 Ko ; ~40 Ko quand il était chargé depuis
  le système de fichiers, qui laissait 34 Ko). Toute nouveauté se mesure avec `Heap` dans
  `Status 4` (en Ko).

## Dépôt

| Chemin | Rôle |
|---|---|
| `platformio_override.ini` | environnement `tasmota32-zbgw03-matter`, dérivé de `tasmota32-zbbrdgpro` + `USE_MATTER_DEVICE` |
| `user_config_override.h` | options de compilation (EZSP, `USE_BERRY_CRYPTO_AES_CBC`...) |
| `patches/*.patch` | correctifs appliqués sur Tasmota par le workflow (`git apply`), dans l'ordre alphabétique |
| `.github/workflows/build.yml` | build : clone Tasmota au commit `TASMOTA_REF`, tests du driver, correctifs, `pio run` |
| `berry/tuya_local.be` | driver Tuya local (protocoles 3.3/3.4/3.5, passerelle Tuya, pont Matter), solidifié dans le firmware (`custom_berry_solidify`) |
| `berry/tuya.example.json` | exemple de configuration, **sans clés** |
| `berry/test/` | banc de test du driver (voir `tests-tuya.md`) |
| `docs/tuya-local.fr.md` | doc utilisateur du driver |
| `docs/tuya-local-suivi.fr.md` | suivi du chantier Tuya |

// Copied to tasmota/user_config_override.h before compilation by the GitHub workflow.

#ifndef _USER_CONFIG_OVERRIDE_H_
#define _USER_CONFIG_OVERRIDE_H_

// eWeLink ZB-GW03: the Zigbee module is an EFR32MG21 (Silicon Labs, EmberZNet firmware),
// which speaks EZSP. The ZBBridge Pro build assumes a CC2652P (Texas Instruments, ZNP).
// The two protocols are mutually exclusive: only one can be compiled.
#undef  USE_ZIGBEE_ZNP
#define USE_ZIGBEE_EZSP

// Berry: AES-CBC, also used for the AES-ECB (block by block, null IV) of the Tuya local
// protocols 3.3 and 3.4
#undef  USE_BERRY_CRYPTO_AES_CBC
#define USE_BERRY_CRYPTO_AES_CBC

#endif  // _USER_CONFIG_OVERRIDE_H_

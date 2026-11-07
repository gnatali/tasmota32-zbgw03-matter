// Copie dans tasmota/user_config_override.h avant la compilation par le workflow GitHub.

#ifndef _USER_CONFIG_OVERRIDE_H_
#define _USER_CONFIG_OVERRIDE_H_

// eWeLink ZB-GW03 : le module Zigbee est un EFR32MG21 (Silicon Labs, firmware EmberZNet),
// qui parle EZSP. Le build ZBBridge Pro suppose un CC2652P (Texas Instruments, ZNP).
// Les deux protocoles s'excluent : un seul peut etre compile.
#undef  USE_ZIGBEE_ZNP
#define USE_ZIGBEE_EZSP

// Berry : AES-CBC, qui sert aussi a l'AES-ECB (bloc par bloc, IV nul) des protocoles
// locaux Tuya 3.3 et 3.4
#undef  USE_BERRY_CRYPTO_AES_CBC
#define USE_BERRY_CRYPTO_AES_CBC

#endif  // _USER_CONFIG_OVERRIDE_H_

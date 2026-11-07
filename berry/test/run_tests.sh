#!/usr/bin/env bash
# Tests du driver tuya_local.be, hors de la passerelle.
#
# Compile un interpreteur Berry (celui de Tasmota) avec un module crypto natif sur le BearSSL
# de Tasmota (AES-CBC, AES-GCM avec AAD comme le correctif, HMAC-SHA256, MD5), puis joue les
# scenarios de test_tuya_local.py contre de faux appareils Tuya construits sur TinyTuya.
#
# Les scenarios sont joues deux fois :
#   1. driver source : le harnais compile tuya_local.be (mode strict, comme load() dans Tasmota) ;
#   2. driver solidifie : tuya_local.be est solidifie comme au build (custom_berry_solidify,
#      port Python de Berry, une classe native par directive `#@ solidify:`), et les classes
#      sont compilees dans l'interpreteur, en lecture seule comme dans la flash de l'ESP32.
#
# Usage : berry/test/run_tests.sh <depot Tasmota>
# Ecrit /tuya.json (configuration fictive) : a lancer dans un conteneur ou une CI.
set -euo pipefail

TASMOTA=$(cd "${1:?usage: run_tests.sh <depot Tasmota>}" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVER="$HERE/../tuya_local.be"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

LIB="$TASMOTA/lib/libesp32"
SSL="$TASMOTA/lib/lib_ssl/bearssl-esp8266/src"
# meme disposition que dans Tasmota : solidify_all_python.be lit ../../../tasmota/...
WLIB="$WORK/lib/libesp32"
mkdir -p "$WLIB" "$WORK/tasmota" "$WORK/obj"

# Berry de Tasmota (le Makefile attend ses voisins re1.5, berry_mapping...)
for d in berry re1.5 berry_mapping berry_int64 berry_custom; do cp -r "$LIB/$d" "$WLIB/"; done
CUSTOM="$WLIB/berry_custom"

# --- Solidification, comme pio-tools/solidify-from-url.py (avec le correctif du depot) ---
: > "$WORK/tasmota/tasmota_defines_for_berry.be"
cp "$DRIVER" "$CUSTOM/src/embedded/"
(cd "$CUSTOM" && PYTHONPATH=../berry PYTHONUTF8=1 python3 -m berry_port -s -g solidify_all_python.be)
SOLID="$CUSTOM/src/solidify/solidified_tuya_local.h"
CLASSES=$(grep -oP '^#@ solidify:\K[A-Za-z0-9_]+' "$DRIVER")
for c in $CLASSES; do
  grep -q "^be_local_class($c," "$SOLID" || { echo "classe $c absente de $(basename "$SOLID")"; exit 1; }
done
printf '#include "be_constobj.h"\n#include "solidify/solidified_tuya_local.h"\n' > "$CUSTOM/src/be_tuya_local_lib.c"

# Table des chaines (coc) : sources de Berry + classes solidifiees, comme
# pio-tools/gen-berry-structures.py. Generee apres la derniere modification des sources et
# avant make, qui la garde donc (plus recente que les sources).
cd "$WLIB/berry"
rm -f berry.exe
sed -i 's|    bvm \*vm = be_vm_new(); /\* create a virtual machine instance \*/|&\n    { extern void be_test_crypto_init(bvm*); be_test_crypto_init(vm); }|' default/berry.c
grep -q be_test_crypto_init default/berry.c
mkdir -p generate
python3 tools/coc/coc -o generate src default ../re1.5 ../berry_mapping/src ../berry_int64/src \
  ../berry_custom/src/solidify -c default/berry_conf.h >/dev/null
touch generate/*

make -j"$(nproc)" >/dev/null 2>&1 || true      # l'edition de liens echoue (symbole de test), les .o suffisent
INC="-Isrc -Idefault -Igenerate -I../re1.5 -I../berry_mapping/src -I../berry_int64/src"

# be_modtab.c inclut berry_custom/src/modules.h : vide pour le driver source, et avec les
# classes du driver pour le driver solidifie (ce qu'ecrit le script de solidification)
mv default/be_modtab.o "$WORK/obj/modtab_source.o"
{
  printf '#define CUSTOM_NATIVE_MODULES\n#define CUSTOM_NATIVE_CLASSES'
  for c in $CLASSES; do printf ' &be_native_class(%s),' "$c"; done
  for c in $CLASSES; do printf '\nbe_extern_native_class(%s);' "$c"; done
  printf '\n'
} > "$CUSTOM/src/modules.h"
gcc -w -std=c99 -O1 -DUSE_BERRY_INT64 $INC -c default/be_modtab.c -o "$WORK/obj/modtab_solid.o"
gcc -w -std=c99 -O1 -DUSE_BERRY_INT64 $INC -c "$CUSTOM/src/be_tuya_local_lib.c" -o "$WORK/obj/tuya_solid.o"

# BearSSL + module crypto de test
mkdir -p "$WORK/obj/ssl"
for f in symcipher/aes_small_cbcenc symcipher/aes_small_cbcdec symcipher/aes_small_dec symcipher/aes_small_enc \
         symcipher/aes_common symcipher/aes_small_ctr aead/gcm hash/ghash_ctmul32 mac/hmac hash/sha2small \
         hash/md5 codec/enc32be codec/dec32be codec/enc32le codec/dec32le codec/ccopy; do
  gcc -w -O1 -c -I"$SSL" -I"$SSL/.." "$SSL/$f.c" -o "$WORK/obj/ssl/$(basename "$f").o"
done
gcc -w -O1 -c -I"$SSL" -I"$SSL/.." -Isrc "$HERE/testcrypto.c" -o "$WORK/obj/ssl/testcrypto.o"

OBJS=$(find src default ../re1.5 ../berry_mapping/src ../berry_int64/src -name '*.o')
gcc $OBJS "$WORK/obj/modtab_source.o" "$WORK"/obj/ssl/*.o -lm -o "$WORK/berry-source"
gcc $OBJS "$WORK/obj/modtab_solid.o" "$WORK/obj/tuya_solid.o" "$WORK"/obj/ssl/*.o -lm -o "$WORK/berry-solid"

python3 -c "import tinytuya" 2>/dev/null || pip install -q tinytuya
cd "$HERE"
echo "== driver source (tuya_local.be compile par le harnais)"
python3 -I test_tuya_local.py "$WORK/berry-source"
echo "== driver solidifie ($(echo $CLASSES | wc -w) classes natives, $(wc -c < "$SOLID") octets de C)"
python3 -I test_tuya_local.py "$WORK/berry-solid"

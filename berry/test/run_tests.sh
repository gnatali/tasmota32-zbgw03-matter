#!/usr/bin/env bash
# Tests of the tuya_local.be driver, away from the gateway.
#
# Builds a Berry interpreter (Tasmota's) with a native crypto module on Tasmota's BearSSL
# (AES-CBC, AES-GCM with AAD like the patch, HMAC-SHA256, MD5), then runs the scenarios of
# test_tuya_local.py against fake Tuya devices built on TinyTuya.
#
# The scenarios run twice:
#   1. source driver: the harness compiles tuya_local.be (strict mode, like load() in Tasmota);
#   2. solidified driver: tuya_local.be is solidified as in the build (custom_berry_solidify,
#      Python port of Berry, one native class per `#@ solidify:` directive), and the classes
#      are compiled into the interpreter, read-only as in the ESP32's flash.
#
# Usage: berry/test/run_tests.sh <Tasmota repository>
# Writes /tuya.json, /tuya.json.bak, /devices.json and /tuya_cloud.json (fake data): run it in
# a container or a CI.
set -euo pipefail

TASMOTA=$(cd "${1:?usage: run_tests.sh <depot Tasmota>}" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
DRIVER="$HERE/../tuya_local.be"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

LIB="$TASMOTA/lib/libesp32"
SSL="$TASMOTA/lib/lib_ssl/bearssl-esp8266/src"
# same layout as in Tasmota: solidify_all_python.be reads ../../../tasmota/...
WLIB="$WORK/lib/libesp32"
mkdir -p "$WLIB" "$WORK/tasmota" "$WORK/obj"

# Tasmota's Berry (the Makefile expects its neighbours re1.5, berry_mapping...)
for d in berry re1.5 berry_mapping berry_int64 berry_custom; do cp -r "$LIB/$d" "$WLIB/"; done
CUSTOM="$WLIB/berry_custom"

# --- Solidification, like pio-tools/solidify-from-url.py (with this repository's patch) ---
: > "$WORK/tasmota/tasmota_defines_for_berry.be"
cp "$DRIVER" "$CUSTOM/src/embedded/"
(cd "$CUSTOM" && PYTHONPATH=../berry PYTHONUTF8=1 python3 -m berry_port -s -g solidify_all_python.be)
SOLID="$CUSTOM/src/solidify/solidified_tuya_local.h"
CLASSES=$(grep -oP '^#@ solidify:\K[A-Za-z0-9_]+' "$DRIVER")
for c in $CLASSES; do
  grep -q "^be_local_class($c," "$SOLID" || { echo "class $c missing from $(basename "$SOLID")"; exit 1; }
done
printf '#include "be_constobj.h"\n#include "solidify/solidified_tuya_local.h"\n' > "$CUSTOM/src/be_tuya_local_lib.c"

# String table (coc): Berry sources + solidified classes, like
# pio-tools/gen-berry-structures.py. Generated after the last change to the sources and before
# make, which therefore keeps it (newer than the sources).
cd "$WLIB/berry"
rm -f berry.exe
sed -i 's|    bvm \*vm = be_vm_new(); /\* create a virtual machine instance \*/|&\n    { extern void be_test_crypto_init(bvm*); be_test_crypto_init(vm); }|' default/berry.c
grep -q be_test_crypto_init default/berry.c
mkdir -p generate
python3 tools/coc/coc -o generate src default ../re1.5 ../berry_mapping/src ../berry_int64/src \
  ../berry_custom/src/solidify -c default/berry_conf.h >/dev/null
touch generate/*

make -j"$(nproc)" >/dev/null 2>&1 || true      # linking fails (test symbol), the .o files are enough
INC="-Isrc -Idefault -Igenerate -I../re1.5 -I../berry_mapping/src -I../berry_int64/src"

# be_modtab.c includes berry_custom/src/modules.h: empty for the source driver, and with the
# driver's classes for the solidified driver (what the solidification script writes)
mv default/be_modtab.o "$WORK/obj/modtab_source.o"
{
  printf '#define CUSTOM_NATIVE_MODULES\n#define CUSTOM_NATIVE_CLASSES'
  for c in $CLASSES; do printf ' &be_native_class(%s),' "$c"; done
  for c in $CLASSES; do printf '\nbe_extern_native_class(%s);' "$c"; done
  printf '\n'
} > "$CUSTOM/src/modules.h"
gcc -w -std=c99 -O1 -DUSE_BERRY_INT64 $INC -c default/be_modtab.c -o "$WORK/obj/modtab_solid.o"
gcc -w -std=c99 -O1 -DUSE_BERRY_INT64 $INC -c "$CUSTOM/src/be_tuya_local_lib.c" -o "$WORK/obj/tuya_solid.o"

# BearSSL + test crypto module
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
echo "== source driver (tuya_local.be compiled by the harness)"
python3 -I test_tuya_local.py "$WORK/berry-source"
echo "== solidified driver ($(echo $CLASSES | wc -w) native classes, $(wc -c < "$SOLID") bytes of C)"
python3 -I test_tuya_local.py "$WORK/berry-solid"

#!/usr/bin/env bash
#
# mayhem/build.sh — build the strongSwan fuzz harnesses (OSS-Fuzz set: *_def/_cus variants, ids, ike,
# pa_tnc, pb_tnc, radius, tls, vici) and the libstrongswan unit-test runner for mayhem/test.sh.
# Both builds are out-of-tree under mayhem/build-{fuzz,test} (gitignored via mayhem/.gitignore), so a
# `git clean -ffdX` removes them and this script recreates everything from committed files.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

# --with-printf-hooks=builtin: strongSwan formats %Y/%N/%B itself instead of registering glibc printf
# specifiers, which ASan's printf interceptor would flag as "unexpected format specifier".

# Three UBSan checks are relaxed (none is in OSS-Fuzz's UBSan set); ASan and the rest of UBSan stay on
# and halting:
#   function          method tables call through void*-typed pointers (e.g. hashtable->put) on every init
#   pointer-overflow  `NULL + 0` arithmetic on empty chunks
#   nonnull-attribute NULL ptr with len 0 passed to memchr/strncasecmp
RELAX="-fno-sanitize=function,pointer-overflow,nonnull-attribute"

cd "$SRC"
[ -f configure ] || ./autogen.sh

# --- 1) tests build, NORMAL flags (an independent oracle build) ------------------------------------
mkdir -p mayhem/build-test
(
  cd mayhem/build-test
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    ../../configure CC="$CC" CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
  make -j"$MAYHEM_JOBS" -C src/libstrongswan
  make -j"$MAYHEM_JOBS" -C src/libstrongswan/tests libstrongswan_tests
)

# --- 2) sanitized project libraries (monolithic static, as upstream's fuzzing CI) -------------------
# -fsanitize=fuzzer-no-link puts SanCov edge counters into the project code (needed for edges>0).
COV=
case "$LIB_FUZZING_ENGINE" in *fuzzer*) COV="-fsanitize=fuzzer-no-link" ;; esac
mkdir -p mayhem/build-fuzz
B="$SRC/mayhem/build-fuzz"
(
  cd mayhem/build-fuzz
  CFLAGS="$SANITIZER_FLAGS $RELAX $DEBUG_FLAGS $COV -O1 -DNO_CHECK_MEMWIPE" LDFLAGS="$SANITIZER_FLAGS" \
    ../../configure CC="$CC" --enable-fuzzing --with-libfuzzer="$LIB_FUZZING_ENGINE" \
      --with-printf-hooks=builtin --enable-monolithic --enable-static --disable-shared --disable-scripts \
      --enable-imc-test --enable-tnccs-20 --enable-eap-radius \
      --enable-sha1 --enable-sha2 --enable-sha3 --enable-mgf1 --enable-gmp
  for lib in libstrongswan libtncif libtpmtss libimcv libtnccs libtls libradius libcharon; do
    make -j"$MAYHEM_JOBS" -C src/$lib
  done
)

# --- 3) harnesses: libFuzzer binary + non-fuzzer standalone reproducer, both with LSan switched off --
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"

FD_PLUGINS=$(sed -n 's/^fd_plugins = //p' "$B/fuzz/Makefile")
FC_PLUGINS=$(sed -n 's/^fc_plugins = //p' "$B/fuzz/Makefile")
INC=(-I"$SRC/src/libcharon" -I"$SRC/src/libstrongswan" -I"$SRC/src/libimcv" -I"$SRC/src/libtncif"
     -I"$SRC/src/libtpmtss" -I"$SRC/src/libtls" -I"$SRC/src/libtnccs"
     -I"$SRC/src/libtnccs/plugins/tnccs_20" -I"$SRC/src/libradius" -I"$B" -include "$B/config.h")
L() { for l in "$@"; do printf '%s ' "$B/src/lib$l/.libs/lib$l.a"; done; }
SYSLIBS="-lcrypto -lgmp -lz -ldl -lpthread -lm"

# harness <out-name> <source> <plugins|-> <libs…>
harness() {
  local out="$1" src="$2" plugins="$3"; shift 3
  local defs=(); [ "$plugins" = - ] || defs=(-DPLUGINS="\"$plugins\"")
  local libs; libs=$(L "$@")
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $RELAX $DEBUG_FLAGS -O1 -DNO_CHECK_MEMWIPE "${INC[@]}" "${defs[@]}" $LIB_FUZZING_ENGINE \
      "$SRC/fuzz/$src" "$B/lsan_off.o" $libs $SYSLIBS -o "$SRC/$out"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $RELAX $DEBUG_FLAGS -O1 -DNO_CHECK_MEMWIPE "${INC[@]}" "${defs[@]}" "$STANDALONE_FUZZ_MAIN" \
      "$SRC/fuzz/$src" "$B/lsan_off.o" $libs $SYSLIBS -o "$SRC/$out-standalone"
}

for f in certs crls ocsp_req ocsp_rsp; do
  harness "fuzz_${f}_def" "fuzz_$f.c" "$FD_PLUGINS" strongswan
  harness "fuzz_${f}_cus" "fuzz_$f.c" "$FC_PLUGINS" strongswan
done
harness fuzz_ids    fuzz_ids.c    - strongswan
harness fuzz_ike    fuzz_ike.c    - charon radius strongswan
harness fuzz_pa_tnc fuzz_pa_tnc.c - imcv tncif tpmtss strongswan
harness fuzz_pb_tnc fuzz_pb_tnc.c - tnccs tncif strongswan
harness fuzz_radius fuzz_radius.c "$FD_PLUGINS" radius strongswan
harness fuzz_tls    fuzz_tls.c    "$FD_PLUGINS" tls strongswan
harness fuzz_vici   fuzz_vici.c   - charon radius strongswan

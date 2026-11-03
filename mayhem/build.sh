#!/usr/bin/env bash
#
# mayhem/build.sh — build FreeRADIUS' libFuzzer harnesses (src/fuzzer) with ASan+UBSan, a run-once
# standalone reproducer per harness, and (independently, with normal flags) the unit_test_attribute
# runner that mayhem/test.sh uses as the functional oracle.
#
# Runs in the commit image as `mayhem` in /mayhem; offline (libkqueue and the -dev packages are
# installed by mayhem/Dockerfile) and re-runnable.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

# Every protocol with a src/fuzzer/fuzzer_<name>.c harness (src/fuzzer/all.mk).
FUZZERS="radius dhcpv4 dhcpv6 dns tacacs vmps tftp bfd cbor arp util json value cf xlat base16_32_64 tmpl der"

# libbacktrace (a submodule that builds inside its own source dir) is switched off so the result does
# not depend on whether the checkout fetched submodules; ASan reports carry the stack traces.
# 1) The project, sanitized, with the fuzzer harnesses. The dictionary and library directories are
#    compiled in (--with-dictdir/--libdir) so the harnesses run with no argv/env: libFuzzer would
#    otherwise treat a `-D <dir>` argument as a corpus directory and write into share/dictionary.
env -u CFLAGS -u LDFLAGS \
    CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS" \
    ./configure CC="$CC" --enable-fuzzer --without-libbacktrace \
        --with-dictdir="$SRC/share/dictionary" --libdir="$SRC/build/lib/local/.libs" \
    > build.configure.log 2>&1 || { tail -50 build.configure.log; exit 1; }
rm -f build.configure.log

TARGETS=""
for f in $FUZZERS; do TARGETS="$TARGETS build/bin/local/fuzzer_$f"; done
# shellcheck disable=SC2086
make -j"$MAYHEM_JOBS" $TARGETS

# 2) Re-link every harness with the LSan-off hook, and once more against the run-once driver as
#    /mayhem/fuzzer_<name>-standalone. The link line is the one make itself used.
mkdir -p build/mayhem
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o build/mayhem/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/mayhem/standalone_main.o

for f in $FUZZERS; do
    exe="build/bin/local/fuzzer_$f"
    mv "$exe" "$exe.keep"
    link="$(make -n "$exe" | grep -F -- '--mode=link' | grep -F -- "-o $exe " | tail -n 1)"
    mv "$exe.keep" "$exe"
    [ -n "$link" ] || { echo "no link line found for $exe" >&2; exit 1; }

    eval "$link build/mayhem/lsan_off.o"

    standalone="${link/-o $exe /-o $SRC/fuzzer_$f-standalone }"
    standalone="${standalone// -fsanitize=fuzzer / }"
    eval "$standalone build/mayhem/standalone_main.o build/mayhem/lsan_off.o"
done

# 3) The unit-test oracle: a separate tree of the tracked sources built with the project's NORMAL
#    flags (no sanitizers, no fuzzer). mayhem/test.sh runs unit_test_attribute from there.
O="$SRC/build/oracle"
mkdir -p "$O"
git ls-files -z | tar --null --no-recursion -T - -cf - | tar -C "$O" -xf -
if [ ! -d "$O/.git" ]; then
    git -C "$O" init -q
    git -C "$O" -c user.name=oracle -c user.email=oracle@localhost commit -q --allow-empty -m oracle
fi
(
    cd "$O"
    unset CFLAGS LDFLAGS
    if [ -n "$COVERAGE_FLAGS" ]; then export CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"; fi
    ./configure CC="$CC" --without-libbacktrace > build.configure.log 2>&1 || { tail -50 build.configure.log; exit 1; }
    make -j"$MAYHEM_JOBS" build/bin/local/unit_test_attribute
)

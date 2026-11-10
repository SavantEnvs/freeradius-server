#!/usr/bin/env bash
#
# mayhem/build.sh — build FreeRADIUS' unit_test_module (a virtual server driven by one canned request) with
# ASan+UBSan, and (independently, with normal flags) the unit_test_attribute runner that mayhem/test.sh uses as
# the functional oracle.
#
# Runs in the commit image as `mayhem` in /mayhem; offline (libkqueue and the -dev packages are
# installed by mayhem/Dockerfile) and re-runnable.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

SEEDS="mayhem/unit_test_module-mined-a3ceda8/testsuite"

# The protocol libraries are dlopen()ed (the radius dictionary refers to dhcpv4/dhcpv6, and the unit-test scripts
# under src/tests/unit/protocols/<proto> use their own), so make cannot see the dependency.
PROTO_LIBS=""
for d in src/tests/unit/protocols/*/; do
    proto="$(basename "$d")"
    [ "$proto" = dict ] || PROTO_LIBS="$PROTO_LIBS build/lib/local/libfreeradius-$proto.la"
done

# libbacktrace (a submodule that builds inside its own source dir) is switched off so the result does
# not depend on whether the checkout fetched submodules; ASan reports carry the stack traces.
# 1) The project, sanitized. The dictionary and library directories are compiled in
#    (--with-dictdir/--libdir) so the server finds them with no -D/-l arguments.
env -u CFLAGS -u LDFLAGS \
    CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS" \
    ./configure CC="$CC" --without-libbacktrace \
        --with-dictdir="$SRC/share/dictionary" --libdir="$SRC/build/lib/local/.libs" \
    > build.configure.log 2>&1 || { tail -50 build.configure.log; exit 1; }
rm -f build.configure.log

# unit_test_module loads the modules and process libraries the configuration names, and the seed
# configurations include raddb/mods-enabled/always.
LIBS="$(sh scripts/build/config-libs.sh "$SEEDS"/*.conf | sort -u | sed 's,^,build/lib/local/,')"
# shellcheck disable=SC2086
make -j"$MAYHEM_JOBS" build/bin/local/unit_test_module $LIBS $PROTO_LIBS raddb/mods-enabled/always

# 2) Re-link unit_test_module with the LSan-off hook. The link line is the one make itself used.
mkdir -p build/mayhem
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o build/mayhem/lsan_off.o
exe=build/bin/local/unit_test_module
mv "$exe" "$exe.keep"
link="$(make -n "$exe" | grep -F -- '--mode=link' | grep -F -- "-o $exe " | tail -n 1)"
mv "$exe.keep" "$exe"
[ -n "$link" ] || { echo "no link line found for $exe" >&2; exit 1; }
eval "$link build/mayhem/lsan_off.o"

# 3) The unit-test oracle: a separate tree of the tracked sources built with the project's NORMAL
#    flags (no sanitizers). mayhem/test.sh runs unit_test_attribute from there.
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
    # shellcheck disable=SC2086
    make -j"$MAYHEM_JOBS" build/bin/local/unit_test_attribute $PROTO_LIBS \
        build/lib/local/libfreeradius-unlang.la build/lib/local/libfreeradius-eap-aka-sim.la
)

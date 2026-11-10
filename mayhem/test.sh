#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# FreeRADIUS' own unit tests: src/tests/unit/**/*.txt are command scripts for unit_test_attribute
# (encode/decode a value, `match` the exact expected bytes or text). build.sh built the runner with
# normal flags in $SRC/build/oracle. Each script is run with -w, which rewrites the file in place with
# the ACTUAL output of every `match` line (all other lines verbatim) — so a script passes only if it
# exits 0, the rewrite really happened, and the rewritten file is byte-identical to the checked-in
# one, i.e. every known input produced exactly the known output.
O="$SRC/build/oracle"
UTA="build/bin/local/unit_test_attribute"
cd "$O"   # expected outputs embed paths relative to the tree root (e.g. dict/base.txt)
[ -x "$UTA" ] || { echo "missing $UTA — mayhem/build.sh did not build the oracle" >&2; emit_ctrf "freeradius-unit" 0 1 0; exit 1; }

export FR_LIBRARY_PATH="$O/build/lib/local/.libs" TZ=GMT
UTA_ARGS=(-F src/tests/fuzzer-corpus -D share/dictionary -d src/tests/unit)
SCRATCH=build/oracle-test
mkdir -p "$SCRATCH"

passed=0; failed=0

# Known-answer probes: a deliberately wrong expectation must be REJECTED, and must report the exact
# value the library produced; a right one (both directions) must be accepted.
cat > "$SCRATCH/kat_enc_ok.txt" <<'EOT'
proto radius
proto-dictionary radius
encode-pair User-Name = "bob"
match 01 05 62 6f 62
EOT
cat > "$SCRATCH/kat_dec_ok.txt" <<'EOT'
proto radius
proto-dictionary radius
decode-pair 01 05 62 6f 62
match User-Name = "bob"
EOT
cat > "$SCRATCH/kat_enc_bad.txt" <<'EOT'
proto radius
proto-dictionary radius
encode-pair User-Name = "bob"
match 01 05 62 6f 63
EOT
for k in kat_enc_ok kat_dec_ok; do
  if "$UTA" "${UTA_ARGS[@]}" "$SCRATCH/$k.txt" > "$SCRATCH/$k.out" 2>&1; then
    passed=$((passed+1))
  else
    failed=$((failed+1)); echo "FAIL probe $k"; tail -5 "$SCRATCH/$k.out"
  fi
done
if "$UTA" "${UTA_ARGS[@]}" "$SCRATCH/kat_enc_bad.txt" > "$SCRATCH/kat_enc_bad.out" 2>&1; then
  failed=$((failed+1)); echo "FAIL probe kat_enc_bad: wrong expectation accepted"
elif grep -qF 'GOT      : 01 05 62 6f 62' "$SCRATCH/kat_enc_bad.out" \
  && grep -qF 'EXPECTED : 01 05 62 6f 63' "$SCRATCH/kat_enc_bad.out"; then
  passed=$((passed+1))
else
  failed=$((failed+1)); echo "FAIL probe kat_enc_bad: wrong output"; tail -5 "$SCRATCH/kat_enc_bad.out"
fi

# The checked-in unit-test scripts.
while IFS= read -r -d '' rel; do
  f="$rel"
  cp "$SRC/$rel" "$f"
  touch -d @0 "$f"
  if timeout 300 "$UTA" "${UTA_ARGS[@]}" -w "$SCRATCH/rewrite.out" "$f" > "$SCRATCH/run.log" 2>&1 \
     && [ "$(stat -c %Y "$f")" -gt 0 ] && cmp -s "$SRC/$rel" "$f"; then
    passed=$((passed+1))
  else
    failed=$((failed+1)); echo "FAIL $rel"; tail -8 "$SCRATCH/run.log"
  fi
  cp "$SRC/$rel" "$f"
done < <(cd "$SRC" && printf '%s\0' src/tests/unit/protocols/*/*.txt src/tests/unit/*.txt)

emit_ctrf "freeradius-unit_test_attribute" "$passed" "$failed" 0

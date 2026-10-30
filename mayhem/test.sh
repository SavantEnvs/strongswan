#!/usr/bin/env bash
#
# mayhem/test.sh — RUN strongSwan's own libstrongswan unit-test runner (built by mayhem/build.sh with
# the project's normal flags). Its per-suite known-answer/behavior assertions (crypto test vectors,
# identification/chunk/settings/traffic-selector semantics, ...) are counted into a CTRF report.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

dir="$SRC/mayhem/build-test/src/libstrongswan/tests"
if [ ! -x "$dir/libstrongswan_tests" ]; then
  echo "libstrongswan_tests missing — mayhem/build.sh must build it" >&2
  emit_ctrf "strongswan-unit" 0 1 0
  exit 1
fi

out=$(mktemp)
trap 'rm -f "$out"' EXIT
(cd "$dir" && TESTS_VERBOSITY=0 ./libstrongswan_tests) > "$out" 2>&1
rc=$?
sed -i 's/\x1b\[[0-9;]*m//g' "$out"

# per-suite summary lines: "Passed all N 'suite' test cases" / "Passed P/N 'suite' test cases"
passed=0; failed=0; suites=0
while read -r p n; do
  passed=$(( passed + p )); failed=$(( failed + n - p )); suites=$(( suites + 1 ))
done < <(sed -n -e "s/^ *Passed all \([0-9]*\) '.*' test cases.*/\1 \1/p" \
                -e "s|^ *Passed \([0-9]*\)/\([0-9]*\) '.*' test cases.*|\1 \2|p" "$out")

# the program must have run the whole runner to its final summary, with a sane number of suites
if ! grep -q "^Passed all [0-9]* 'libstrongswan' suites" "$out" && [ "$rc" -eq 0 ]; then
  failed=$(( failed + 1 ))
fi
if [ "$suites" -lt 40 ]; then
  failed=$(( failed + 1 ))
fi
[ "$rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
[ "$failed" -eq 0 ] || tail -40 "$out" >&2
emit_ctrf "strongswan-unit" "$passed" "$failed" 0

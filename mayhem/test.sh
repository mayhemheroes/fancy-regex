#!/usr/bin/env bash
#
# mayhem/test.sh — RUN fancy-regex's OWN test suite (compiled by mayhem/build.sh via
# `cargo test --no-run` into $SRC/mayhem/test-target). This script only RUNS the
# prebuilt runners; it never compiles.
#
# fancy-regex ships a large real suite: unit tests (#[cfg(test)] in src/*.rs) plus
# integration tests in tests/ (matching.rs, captures.rs, replace.rs, finding.rs,
# splitting.rs, regex_options.rs, oniguruma.rs). These are known-answer / behavior
# tests — they assert parsed values, match positions, capture groups, replacements,
# etc., NOT just exit status. So a PATCH that neuters the engine to a no-op / exit(0)
# produces failing tests (or no "test result:" marker) and FAILS here
# (anti-reward-hacking, SPEC §6.3). Emits a CTRF summary; exit 0 iff failed==0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

TARGET_DIR="$SRC/mayhem/test-target"

# Locate the prebuilt test runner binaries. cargo names each runner
# <crate>-<hash> (no extension) and marks it executable under debug/deps. This
# covers BOTH the lib unit-test runner (fancy_regex-*) and each integration test
# binary (matching-*, captures-*, replace-*, finding-*, splitting-*,
# regex_options-*, oniguruma-*). We exclude *.d dep files and *.rlib/*.so.
mapfile -t RUNNERS < <(
  find "$TARGET_DIR/debug/deps" -maxdepth 1 -type f -executable \
    ! -name '*.d' ! -name '*.rlib' ! -name '*.so' 2>/dev/null | sort
)
if [ "${#RUNNERS[@]}" -eq 0 ]; then
  echo "FATAL: no prebuilt test runners under $TARGET_DIR/debug/deps — build.sh should have produced them" >&2
  emit_ctrf "cargo-test" 0 1
  exit 1
fi

passed_total=0
failed_total=0
skipped_total=0
saw_marker=0

for runner in "${RUNNERS[@]}"; do
  echo "=== running $runner ==="
  # Run from $SRC so any relative test fixtures resolve. --test-threads bounds
  # parallelism; runners that are not libtest harnesses simply run and exit.
  out="$("$runner" --test-threads="$MAYHEM_JOBS" 2>&1)" && rc=0 || rc=$?
  echo "$out"
  runner_saw=0
  # Parse libtest summary: "test result: ok. N passed; M failed; K ignored; ...".
  while IFS= read -r line; do
    if [[ "$line" =~ test\ result:.*\ ([0-9]+)\ passed\;\ ([0-9]+)\ failed\;\ ([0-9]+)\ ignored ]]; then
      passed_total=$(( passed_total + ${BASH_REMATCH[1]} ))
      failed_total=$(( failed_total + ${BASH_REMATCH[2]} ))
      skipped_total=$(( skipped_total + ${BASH_REMATCH[3]} ))
      saw_marker=1
      runner_saw=1
    fi
  done <<< "$out"
  # A runner that exited nonzero but printed no failure marker still counts as a failure.
  if [ "$rc" -ne 0 ] && [ "$runner_saw" -eq 0 ]; then
    echo "runner exited $rc with no libtest marker — counting as failure" >&2
    failed_total=$(( failed_total + 1 ))
  fi
done

# No summary marker at all ⇒ the binaries never ran the real suite (neutered/no-op) ⇒ FAIL.
if [ "$saw_marker" -eq 0 ]; then
  echo "FATAL: no libtest 'test result:' marker seen — suite did not run" >&2
  emit_ctrf "cargo-test" 0 1
  exit 1
fi
# Sanity floor: the suite must actually pass a meaningful number of tests
# (fancy-regex ships well over 100 #[test]). A near-empty pass count means the
# oracle was gutted.
if [ "$passed_total" -lt 20 ]; then
  echo "FATAL: only $passed_total tests passed (expected >=20) — oracle would be vacuous / gutted" >&2
  emit_ctrf "cargo-test" "$passed_total" $(( failed_total > 0 ? failed_total : 1 )) "$skipped_total"
  exit 1
fi

emit_ctrf "cargo-test" "$passed_total" "$failed_total" "$skipped_total"

#!/usr/bin/env bash
#
# mayhem/build.sh — build gjson.rs's cargo-fuzz target as a sanitized libFuzzer binary
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), then build the upstream test
# suite (normal flags) so mayhem/test.sh can RUN it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# Toolchain + cargo registry at $CARGO_HOME=/opt/toolchains/rust/cargo (absolute,
# $HOME-independent). AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS
# script OFFLINE — this first (online) build populates the registry; do NOT hard-code
# --offline (the rlenv runtime exports CARGO_NET_OFFLINE=true for the re-run).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Sanitizers (§6.1): the base provides clang $SANITIZER_FLAGS (ASan+UBSan, halting).
# rustc can't consume those clang flags, but we honor the KNOB: when $SANITIZER_FLAGS
# is non-empty we instrument the Rust build with ASan (the OSS-Fuzz Rust path); an
# explicit empty `--build-arg SANITIZER_FLAGS=` yields an un-sanitized build. We
# reference $SANITIZER_FLAGS so the fuzzed code is sanitized by default.
RUST_SAN=""
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  RUST_SAN="-Zsanitizer=address"
fi

# Debug info (§6.2 item 10): the produced binary MUST carry DWARF < 4 (Mayhem triage
# can't read DWARF >= 4). rustc nightly defaults to DWARF-5, so we pin -Zdwarf-version=3
# for Rust code. The libfuzzer-sys cc shim is compiled by clang (DWARF-5 default), so we
# pin its DWARF too via CFLAGS/CXXFLAGS. $RUST_DEBUG_FLAGS threads any extra base pins.
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Zdwarf-version=3 -Cdebuginfo=1 -Cforce-frame-pointers"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The bundled ASan runtime archive that `-Zsanitizer=address` links is precompiled
# with clang (DWARF-5) and ships with full debug info, which would otherwise land
# DWARF-5 compile units in the final binary and fail the DWARF < 4 gate. Strip the
# debug info from that runtime archive (a toolchain artifact, NOT project code).
# Idempotent: re-running --strip-debug on an already-stripped archive is a no-op,
# so the offline PATCH re-run stays clean.
if [ -n "${RUST_SAN}" ]; then
  RT_LIB_DIR="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/lib"
  for asan in "$RT_LIB_DIR"/librustc-*_rt.asan.a; do
    [ -f "$asan" ] || continue
    if [ -w "$asan" ]; then
      objcopy --strip-debug "$asan" "$asan.stripped" && mv "$asan.stripped" "$asan"
      echo "stripped debug info from bundled ASan runtime: $asan"
    fi
  done
fi

# Additive cargo-fuzz crate (upstream's own extra/fuzz/ is afl-based, not cargo-fuzz).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it).
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Build the upstream test suite too (clean, NON-sanitized build) ─────────────
# mayhem/test.sh only RUNS this; it never compiles. Debug build (no --release) so
# debug_assertions/assert! stay live — the oracle must bite a neutered binary.
# The target-dir is fixed under $SRC so test.sh finds the runners deterministically.
TEST_TARGET_DIR="$SRC/mayhem/test-target"

# Toolchain-compat pin for the TEST build only (does NOT touch upstream Cargo.toml —
# purely a lockfile resolution nudge, additive & idempotent). fancy-regex's dev-dep
# `criterion 0.5` pulls `ciborium -> half -> zerocopy >=0.8.26`, and recent zerocopy
# uses the still-unstable `stdarch_x86_avx512` intrinsics, which our pinned nightly
# (nightly-2025-05-14, built 2025-05-13) rejects with E0658 — breaking the test
# compile even though the fuzz target builds fine. Pinning `half` back to 2.2.1 drops
# `zerocopy` out of the dependency graph entirely (half 2.2.1 has no zerocopy dep),
# so the suite compiles on the pinned nightly. We resolve a lockfile UNDER the fixed
# test-target dir and pin there, leaving the crate root's ignored Cargo.lock alone.
echo "=== pin dev-dep resolution for the test build (half 2.2.1 -> no zerocopy) ==="
# Generate (or refresh) the lockfile, then downgrade half. Both are no-ops if already
# satisfied, so the offline PATCH re-run (registry pre-populated) stays clean. Guard
# each step so a benign "already at this version" doesn't abort the build.
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo generate-lockfile 2>&1 | tail -3 || true
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS cargo update -p half --precise 2.2.1 2>&1 | tail -3 || true

echo "=== cargo test --no-run (upstream suite, normal flags) ==="
# Build WITHOUT the fuzzing RUSTFLAGS / CFLAGS (a clean, non-sanitized compile).
# --tests builds the lib unit tests + every tests/ integration binary (no doctests,
# which need a separate harness); test.sh runs whatever runners land in test-target.
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS \
  cargo test --no-run --tests --target-dir "$TEST_TARGET_DIR" 2>&1 | tail -25

echo "build.sh complete"

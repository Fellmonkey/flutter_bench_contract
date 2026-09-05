#!/usr/bin/env bash
# bench-contract — container entrypoint: boots the precreated AVD headless,
# then runs the consumer's whole contract (resolved from pub.dev via the
# consumer's own pubspec) in check/record mode — device scenarios + the S7
# native size leg (the web leg stays in plain CI, where it does not need
# the emulator) — plus the card/readme renders when the manifest declares
# them. Run from the consumer root (the workspace mount). Exit codes:
# 0 ok / 1 regression or failed run / 2 usage.
#
# Usage: bench-contract <check|record> [--ref <ref>] [--legs native|web|both]
#                       [--scenarios <a,b>] [--store <path>]
set -euo pipefail

MODE="${1:-}"
shift || true
REF="android"
LEGS="native"
SCENARIOS=""
STORE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="${2:-android}"; shift 2 ;;
    --legs) LEGS="${2:-native}"; shift 2 ;;
    --scenarios) SCENARIOS="${2:-}"; shift 2 ;;
    --store) STORE="${2:-}"; shift 2 ;;
    *) echo "bench-contract: unknown option $1" >&2; exit 2 ;;
  esac
done
if [ "$MODE" != "check" ] && [ "$MODE" != "record" ]; then
  echo "usage: bench-contract <check|record> [--ref <ref>] [--legs native|web|both] [--scenarios <a,b>] [--store <path>]" >&2
  exit 2
fi

CONTRACT="dart run flutter_bench_contract:contract"
[ -f bench_contract.yaml ] || {
  echo "bench-contract: no bench_contract.yaml in $(pwd) — mount the consumer root and run from it" >&2
  exit 2
}

# -- Consumer dependencies (hosted flutter_bench_contract resolves from
# pub.dev; the pubspec.lock in the mounted repo pins it).
flutter pub get >/dev/null

# -- Boot the emulator headless. Software rendering (no GPU in a container);
# hardware accel comes from the host's /dev/kvm, passed through at run time.
EMULATOR_PID=""
cleanup() {
  [ -n "$EMULATOR_PID" ] && kill "$EMULATOR_PID" 2>/dev/null || true
}
trap cleanup EXIT
"${ANDROID_HOME:-/opt/android-sdk}/emulator/emulator" \
  -avd contract \
  -no-window -no-audio -no-boot-anim -no-snapshot -no-snapshot-load -no-snapshot-save \
  -gpu swiftshader_indirect \
  -accel auto \
  -memory 4096 -cores 4 \
  -no-metrics \
  >/dev/null 2>&1 &
EMULATOR_PID=$!

echo "bench-contract: waiting for the emulator to boot..."
booted=0
for _ in $(seq 1 90); do # up to 7.5 min; abort early if the process died
  if ! kill -0 "$EMULATOR_PID" 2>/dev/null; then
    echo "bench-contract: emulator process exited during boot — is /dev/kvm passed through?" >&2
    exit 1
  fi
  if [ "$(adb devices | awk '/^emulator-5554/{print $2}')" = "device" ] &&
     [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    booted=1
    break
  fi
  sleep 5
done
if [ "$booted" != "1" ]; then
  echo "bench-contract: emulator did not boot in time (see above)" >&2
  exit 1
fi
adb shell input keyevent 82 >/dev/null 2>&1 || true # dismiss the lock screen

# -- Hardware/OS stabilization (post-boot quiesce — before contract).
# Reduces wall/heap variance on shared runners: animations off, stay awake,
# trim caches, wait for system to settle. This is the "before test" gate
# from the plan — catches floor drift before per-cycle baseline does.
adb shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
adb shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
adb shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
adb shell svc power stayon true >/dev/null 2>&1 || true
adb shell pm trim-caches 999999999 >/dev/null 2>&1 || true
# Let the system quiesce after boot and after trimming — 10s is enough for
# background dexopt and GC to land, but short enough not to bloat CI (20 min cap).
sleep 10
adb shell dumpsys procstats --reset >/dev/null 2>&1 || true
# Ensure package manager is idle before flutter pub get / drive
for _ in $(seq 1 12); do
  if adb shell pm list packages >/dev/null 2>&1; then break; fi
  sleep 1
done
echo "bench-contract: emulator booted + quiesced ($MODE, ref=$REF)"

# -- The whole contract: device scenarios + the S7 size legs (default
# native — host build inside the container; the web leg stays in plain CI).
# shellcheck disable=SC2086
$CONTRACT run --device emulator-5554 --mode "$MODE" --ref "$REF" \
  --legs "$LEGS" \
  ${SCENARIOS:+--scenarios "$SCENARIOS"} ${STORE:+--store "$STORE"}

# -- Published results (host renders from the recorded store). Only in
# record mode: renders write the card PNG / README section into the mounted
# repo, and a check run must stay read-only (no root-owned writes into the
# consumer's working tree on a gate run).
if [ "$MODE" = "record" ]; then
  if grep -qE '^card:' bench_contract.yaml; then
    echo "bench-contract: metrics card..."
    $CONTRACT card
  fi
  if grep -qE '^readme:' bench_contract.yaml; then
    echo "bench-contract: README section..."
    $CONTRACT readme
  fi
fi

echo "bench-contract: done ($MODE, ref=$REF)"

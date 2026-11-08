#!/usr/bin/env bash
# The Linux rung: what a Linux box can say about BugKit without a Mac.
#   1. The host tests, built and run on Linux. What needs an Apple framework (UIKit, SwiftUI, Combine, CloudKit, the
#      Keychain, Mach, the crash handlers) is left out by `#if canImport` / `#if os`, and so are its tests.
#   2. BugKit and its tests cross-built with a Darwin Swift SDK (xtool's) for macOS, iOS and the iOS simulator:
#      Mach-O compiled, never executed. Skipped, and said so, when no `darwin` SDK is installed.
# Neither replaces the Mac: `swift test` there runs the macOS-only tests (NoteDictation, the Mac dismiss), and the
# simulator bundle (scripts/test-ios-diagnostics.sh) runs the UIKit ones.
#
# Environment (all optional):
#   LINUX_SWIFT_BIN  the Swift toolchain's bin directory, when `swift` on PATH is not the one to use
#   LINUX_LIB_DIR    extra libraries for the toolchain and the link (LD_LIBRARY_PATH and -L), e.g. an ICU it needs
#   BUGKIT_LINUX_BUILD  a build directory to keep between runs (default: a temporary one, removed afterwards)
#   JOBS             build jobs (default 3)
set -uo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Linux ] || { echo "test-linux is the Linux rung; on a Mac run swift test" >&2; exit 2; }
[ -n "${LINUX_SWIFT_BIN:-}" ] && export PATH="$LINUX_SWIFT_BIN:$PATH"
command -v swift >/dev/null || { echo "no swift on PATH (set LINUX_SWIFT_BIN)" >&2; exit 2; }
flags=()
if [ -n "${LINUX_LIB_DIR:-}" ]; then
  export LD_LIBRARY_PATH="$LINUX_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  flags+=(-Xlinker "-L$LINUX_LIB_DIR")
fi
build=${BUGKIT_LINUX_BUILD:-}
if [ -z "$build" ]; then
  build=$(mktemp -d "${TMPDIR:-/tmp}/bugkit-test-linux.XXXXXX")
  trap 'rm -rf "$build"' EXIT
fi
mkdir -p "$build"
jobs=${JOBS:-3}
low() { nice -n 19 ionice -c 3 "$@"; }
fail=0

# Tests that pass on the Mac and fail here for a Linux Foundation reason, not a BugKit one:
#   - aFileThatFailsLeavesTheOthersInTheReport: the "unreadable file" is a directory, whose size is 0 on Linux
#     (overlayfs, btrfs), so it is copied as an empty file instead of failing.
#   - three CloudKit outbox tests: Linux's appendingPathComponent adds a trailing slash once the folder exists, so the
#     fixture's documents URL no longer equals the store's and enqueue throws wrongStore.
skip='aFileThatFailsLeavesTheOthersInTheReport|unstageableEvidenceStopsRetryingUntilStartOrNewReport'
skip+='|writerNamesAGivenUpReportDifferentlyFromAPendingOne|enqueuedReportIsDeliveredEvenIfTheOptInBoundaryAlreadyListedIt'

echo "== $(swift --version 2>&1 | head -1)"
echo "== Linux: swift test ($(uname -m)), skipping 4 Linux-Foundation-only failures"
log=$build/linux-test.log
low swift test -j "$jobs" --scratch-path "$build/linux" --skip "$skip" "${flags[@]}" >"$log" 2>&1
status=$?
grep -E " error: |Fatal error|^✘" "$log" | head -20
xctest=$(grep -E "Executed [0-9]+ tests" "$log" | tail -1 | sed 's/^[[:space:]]*//')
testing=$(grep -E "Test run with [0-9]+ tests" "$log" | tail -1 | sed 's/^[^T]*//')
if [ $status -ne 0 ] || [ -z "$xctest" ] || [ -z "$testing" ]; then
  echo "FAIL Linux swift test (exit $status; log: $log)"
  fail=1
else
  echo "ok   XCTest: $xctest"
  echo "ok   Swift Testing: $testing"
fi

if swift sdk list 2>/dev/null | grep -qx darwin; then
  for triple in arm64-apple-macosx arm64-apple-ios arm64-apple-ios-simulator; do
    sdk=$(swift sdk configure --show-configuration darwin "$triple" 2>/dev/null | sed -n 's/^sdkRootPath: //p')
    log=$build/$triple.log
    # Swift Testing's Foundation overlay (_Testing_Foundation) sits in the platform's frameworks, not the SDK's.
    platform_frameworks=()
    [ -n "$sdk" ] && platform_frameworks=(-Xswiftc -F -Xswiftc "$(dirname "$(dirname "$sdk")")/Library/Frameworks")
    if low swift build --build-tests --build-system native --swift-sdk darwin --triple "$triple" -j "$jobs" \
      --scratch-path "$build/$triple" "${platform_frameworks[@]}" >"$log" 2>&1; then
      echo "ok   cross-build $triple: BugKit + tests compiled, not run (SDK $(basename "${sdk:-?}"))"
    else
      grep -E "error:" "$log" | head -20
      echo "FAIL cross-build $triple (log: $log)"
      fail=1
    fi
  done
else
  echo "SKIP cross-build: no darwin Swift SDK (xtool sdk install)"
fi
# A failure keeps its logs, even in the temporary directory.
if [ $fail -ne 0 ] && [ -z "${BUGKIT_LINUX_BUILD:-}" ]; then
  trap - EXIT
  echo "logs kept in $build"
fi
exit $fail

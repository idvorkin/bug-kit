#!/usr/bin/env bash
# Run inside xcode-signing.lock. Never contact provisioning while the Mac is locked.
# Usage: signing-guard.sh <build-command> [args...]
set -uo pipefail
[ "$#" -gt 0 ] || { echo "usage: signing-guard.sh <build-command> [args...]" >&2; exit 2; }
for tool in ioreg caffeinate; do
  command -v "$tool" >/dev/null || { echo "signing_guard: missing $tool; build not started" >&2; exit 69; }
done
build_log=$(mktemp "${TMPDIR:-/tmp}/bugkit-signing.XXXXXX") || exit 1
caffeinate -d -w $$ &
awake_pid=$!
cleanup() {
  kill "$awake_pid" 2>/dev/null || true
  wait "$awake_pid" 2>/dev/null || true
  rm -f "$build_log"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

waiting=0
while :; do
  if ! state=$(ioreg -n Root -d1); then
    echo "signing_guard: cannot read screen-lock state; build not started" >&2
    exit 69
  fi
  if [ -z "$state" ]; then
    echo "signing_guard: empty screen-lock state; build not started" >&2
    exit 69
  fi
  if ! kill -0 "$awake_pid" 2>/dev/null; then
    echo "signing_guard: display-sleep assertion failed; build not started" >&2
    exit 69
  fi
  if ! grep -qE '"CGSSessionScreenIsLocked"[[:space:]]*=[[:space:]]*(Yes|true)' <<<"$state"; then
    break
  fi
  [ "$waiting" -ne 0 ] || echo "signing_guard: Mac is locked; waiting for the person to unlock it" >&2
  waiting=1
  sleep 5
done
[ "$waiting" -eq 0 ] || echo "signing_guard: Mac unlocked; starting build" >&2

"$@" 2>&1 | tee "$build_log"
statuses=("${PIPESTATUS[@]}")
if grep -qiE 'No Accounts|Failed to load credentials' "$build_log"; then
  echo "signing_guard: Xcode account access failed. Stop: do not retry or install. Unlock the Mac and ask the person to check Xcode Settings > Accounts (docs/ops/signing.md)." >&2
  exit 78
fi
[ "${statuses[0]}" -eq 0 ] || exit "${statuses[0]}"
exit "${statuses[1]}"

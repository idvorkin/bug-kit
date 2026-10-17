#!/usr/bin/env bash
# Run a command with one named simulator held, so two agents cannot both claim it (#47). The whole run holds a lockf
# lock per simulator name. Inside the lock it waits until no simulator is booted, this one included (a caller outside
# the lock may be using it), boots this one, and shuts it down on exit, pass or fail. Create the command's log files inside the command, so two runs' logs cannot interleave.
# Run it under the shared build lock: the per-name lock stops two runs claiming the same simulator, and build.lock
# stops two simulators booting across names. The wait for booted simulators is only a backstop for callers outside
# build.lock, not a guarantee. A failed booted-list query fails the run rather than boot unverified.
#
#   mkdir -p ~/tmp/agent/locks && lockf -k -t 3600 ~/tmp/agent/locks/build.lock scripts/with-simulator.sh <name> [--wait <seconds>] -- <command…>
#
#   <name>   the simulator's name in `xcrun simctl list devices available`; the newest runtime's wins
#   --wait   how long to wait for the lock, and then for booted simulators to shut down (default 1200)
#   The command runs with SIM_UDID set. Exits 75 when another run held <name>, or a simulator stayed booted, for the
#   whole wait; 2 when no simulator has that name; 69 when simctl cannot list booted simulators; 70 when the command
#   passed but the simulator would not shut down.
set -uo pipefail
usage() { echo "usage: with-simulator.sh <name> [--wait <seconds>] -- <command…>" >&2; exit 2; }
name=${1:-}; [ -n "$name" ] || usage; shift
wait=1200
if [ "${1:-}" = --wait ]; then wait=${2:-}; shift 2 || usage; fi
[ "${1:-}" = -- ] || usage; shift
[ $# -gt 0 ] || usage
SIMCTL=${BUG_KIT_SIMCTL:-xcrun simctl}

if [ -z "${BUG_KIT_SIM_HELD:-}" ]; then
  locks=${BUG_KIT_SIM_LOCKS:-$HOME/tmp/agent/locks}
  mkdir -p "$locks"
  lock="$locks/sim-$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_').lock"
  started=$(mktemp)
  trap 'rm -f "$started"' EXIT
  # -k keeps the file, so a waiter never locks one just removed. lockf itself exits 75 when the wait runs out.
  BUG_KIT_SIM_HELD="$started" lockf -k -t "$wait" "$lock" "$0" "$name" --wait "$wait" -- "$@"
  status=$?
  if [ "$status" = 75 ] && [ ! -s "$started" ]; then
    echo "another run held $name for $wait s; nothing ran" >&2
  fi
  exit "$status"
fi
echo held >"$BUG_KIT_SIM_HELD"
unset BUG_KIT_SIM_HELD

udid=$($SIMCTL list devices available | grep -F -- "    $name (" | tail -1 | grep -oE '[0-9A-F-]{36}')
[ -n "$udid" ] || { echo "no simulator named $name" >&2; exit 2; }
deadline=$((SECONDS + wait))
while :; do
  listed=$($SIMCTL list devices booted) || { echo "cannot list booted simulators; nothing ran" >&2; exit 69; }
  booted=$(grep -E '\(Booted\)' <<<"$listed" || true)
  [ -z "$booted" ] && break
  [ "$SECONDS" -ge "$deadline" ] && { echo "a simulator stayed booted for $wait s; nothing ran: $booted" >&2; exit 75; }
  sleep 5
done
# Shut down and verify, so a failed shutdown cannot leave the Mac's one simulator booted behind a passing run.
shutdown_sim() {
  local tries
  for tries in 1 2 3; do
    $SIMCTL shutdown "$udid" >/dev/null 2>&1
    listed=$($SIMCTL list devices booted 2>/dev/null) && ! grep -qF "$udid" <<<"$listed" && return 0
    sleep 1
  done
  echo "could not shut down $name ($udid); shut it down by hand: xcrun simctl shutdown $udid" >&2
  return 1
}
trap 'status=$?; shutdown_sim || { [ "$status" = 0 ] && status=70; }; exit "$status"' EXIT
$SIMCTL bootstatus "$udid" -b >/dev/null || { echo "could not boot $name ($udid)" >&2; exit 1; }
SIM_UDID=$udid "$@"

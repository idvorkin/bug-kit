#!/usr/bin/env bash
# Build an app once and install it on every paired iPhone and iPad (and, with --watch, its watch app on the
# watch), under the Mac-wide signing lock. The shape of EA `run-device`, CG `native-run-device` and MM `just ipad`,
# for all devices at once. See docs/ops/deploying.md and docs/ops/signing.md.
#
#   scripts/deploy-all.sh <app> [--only <device-dir>[,<device-dir>…]] [--register <device-dir>] [--watch] [--dry-run]
#
#   <app>        a name in ~/.config/bug-kit/apps.json whose entry has a "build" object (see listener/apps.example.json)
#   --only       just these devices, by the model folder names the listener uses (iphone-17-pro, ipad-air-11-inch-m3)
#   --register   build with this device as the destination (with -allowProvisioningDeviceRegistration), for a
#                device not yet in the provisioning profile; needs the Xcode account signed in
#   --watch      also install the embedded watch app ("watch_app" in the build object) on each paired watch
#   --dry-run    print the commands; build and install nothing
#
# Rules it keeps (sources in docs/ops):
#   - one signing build at a time on this Mac: the whole run holds `lockf -k -t 900 ~/tmp/agent/locks/xcode-signing.lock`
#     (MM mmn-af8), and inside it waits for any unlocked `xcodebuild … -allowProvisioningUpdates` (anchored pgrep);
#   - a failed build never installs the previous bundle: success is "BUILD SUCCEEDED" in the output (EA #43);
#   - inside the lock, signing-guard.sh waits for Mac unlock and prevents display sleep during the build;
#   - "No Accounts" or "Failed to load credentials" stops the run: tell the person and never retry automatically;
#   - a launch refused because the device is locked (CoreDeviceError 10002) is a soft success: installed, opens when
#     unlocked; a build destination locked at build time ("needs to be unlocked") exits 79 naming the device, not as a
#     build failure; a watch that refuses (1011/4000, usage assertion, timeout) is asleep, not broken.
set -uo pipefail
CONFIG=${BUG_KIT_CONFIG:-$HOME/.config/bug-kit/apps.json}
SIGNING_GUARD=$(cd "$(dirname "$0")" && pwd)/signing-guard.sh
LOCK=${BUG_KIT_SIGNING_LOCK:-$HOME/tmp/agent/locks/xcode-signing.lock}
app=${1:?usage: deploy-all.sh <app> [--only devs] [--register dev] [--watch] [--dry-run]}
shift
only="" register="" watch=0 dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --only) only=$2; shift 2 ;;
    --register) register=$2; shift 2 ;;
    --watch) watch=1; shift ;;
    --dry-run) dry=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

# One signing build at a time: re-run this script under the lock (a kernel lock, dropped when the run ends; -k keeps
# the file so a waiter never locks one just removed). A dry run builds nothing and takes no lock.
if [ "$dry" = 0 ] && [ -z "${BUG_KIT_LOCKED:-}" ]; then
  mkdir -p "$(dirname "$LOCK")"
  echo "waiting for the signing lock ($LOCK, up to 15 min)…"
  BUG_KIT_LOCKED=1 exec lockf -k -t 900 "$LOCK" "$0" "$app" ${only:+--only "$only"} ${register:+--register "$register"} \
    $([ "$watch" = 1 ] && echo --watch)
fi

exec 3>&2  # the terminal's stderr, kept for run() and the guard's own messages when output is captured
run() {  # prints the command; runs it unless --dry-run
  { printf '+ '; printf '%q ' "$@"; echo; } >&3
  [ "$dry" = 1 ] || "$@"
}

cfg=$(jq -c --arg a "$app" '.apps[] | select(.name == $a)' "$CONFIG")
[ -n "$cfg" ] || { echo "no app '$app' in $CONFIG" >&2; exit 2; }
build=$(jq -c '.build // empty' <<<"$cfg")
[ -n "$build" ] || { echo "'$app' has no \"build\" object in $CONFIG" >&2; exit 2; }
repo=$(jq -r '.repo' <<<"$cfg"); repo=${repo/#\~/$HOME}
bundle=$(jq -r '.bundle' <<<"$cfg")
dir="$repo/$(jq -r '.build.dir // "."' <<<"$cfg")"
scheme=$(jq -r '.build.scheme' <<<"$cfg")
project=$(jq -r '.build.project // empty' <<<"$cfg")
workspace=$(jq -r '.build.workspace // empty' <<<"$cfg")
derived=$(jq -r '.build.derived_data // "Build"' <<<"$cfg")
product=$(jq -r '.build.app' <<<"$cfg")
watch_app=$(jq -r '.build.watch_app // empty' <<<"$cfg")
xcodegen=$(jq -r '.build.xcodegen // empty' <<<"$cfg")  # the folder holding project.yml, relative to the repo
settings=()  # bash 3.2 (macOS /bin/bash) has no mapfile
# Build settings: {sha} and {branch} become the repo's short commit and branch (CG bakes them into About);
# {describe} is the short commit plus "-dirty" when the tree has uncommitted changes (MM), for BUGKIT_COMMIT.
sha=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)
branch=$(git -C "$repo" branch --show-current 2>/dev/null || echo unknown)
describe=$(git -C "$repo" describe --always --dirty --exclude='*' 2>/dev/null || echo unknown)
while IFS= read -r s; do
  [ -n "$s" ] || continue
  s=${s//\{sha\}/$sha}; s=${s//\{describe\}/$describe}; settings+=("${s//\{branch\}/$branch}")
done < <(jq -r '.build.settings // [] | .[]' <<<"$cfg")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun devicectl list devices --json-output "$tmp/devices.json" >/dev/null 2>&1 || { echo "devicectl list devices failed" >&2; exit 1; }
jq -r '[.result.devices[] | select(.hardwareProperties.reality == "physical")]
       | map({id: .identifier, udid: .hardwareProperties.udid, type: .hardwareProperties.deviceType,
              dir: ((.hardwareProperties.marketingName // .hardwareProperties.productType)
                    | ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-"))})
       | .[] | "\(.dir) \(.id) \(.udid) \(.type)"' "$tmp/devices.json" >"$tmp/all"
phones=$(awk '$4 == "iPhone" || $4 == "iPad"' "$tmp/all")
if [ -n "$only" ]; then phones=$(grep -E "^($(tr ',' '|' <<<"$only")) " <<<"$phones" || true); fi
[ -n "$phones" ] || { echo "no matching paired iPhone or iPad"; exit 1; }
echo "devices:"; awk '{print "  " $1 " (" $4 ")"}' <<<"$phones"

# The destination: the device being registered, else the first one. Its hardware UDID, as xcodebuild wants.
dest_line=$(if [ -n "$register" ]; then grep "^$register " <<<"$phones"; else head -1 <<<"$phones"; fi)
[ -n "$dest_line" ] || { echo "no device '$register'" >&2; exit 2; }
dest_udid=$(awk '{print $3}' <<<"$dest_line")

cd "$dir" || { echo "no build dir $dir" >&2; exit 2; }
if [ "$dry" = 0 ]; then
  # Signing builds that did not take the lock (another repo's recipe): wait for them. Anchored, so other agents'
  # shells that merely mention xcodebuild do not count (a bare `pgrep -f xcodebuild` once saw 30 "builds").
  signing='^[^ ]*xcodebuild .*-allowProvisioningUpdates'
  for i in $(seq 1 180); do
    others=$(pgrep -fl "$signing" || true)
    [ -z "$others" ] && break
    [ "$i" = 1 ] && echo "waiting for another signing build to finish: $others"
    sleep 5
  done
  [ -n "$(pgrep -f "$signing" || true)" ] && { echo "error: another signing build is still running after 15 minutes" >&2; exit 1; }
fi
# After any project.yml change, or the build silently uses the old project.
[ -n "$xcodegen" ] && { (cd "$repo/$xcodegen" && run xcodegen generate --quiet) || { echo "xcodegen failed" >&2; exit 1; }; }

container=(-project "$project"); [ -n "$workspace" ] && container=(-workspace "$workspace")
echo "building $scheme once, for $(awk '{print $1}' <<<"$dest_line")"
if [ "$dry" = 1 ]; then
  run xcodebuild "${container[@]}" -scheme "$scheme" -derivedDataPath "$derived" -destination "platform=iOS,id=$dest_udid" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration ${settings[@]+"${settings[@]}"} build
else
  out=$("$SIGNING_GUARD" xcodebuild "${container[@]}" -scheme "$scheme" -derivedDataPath "$derived" \
    -destination "platform=iOS,id=$dest_udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    ${settings[@]+"${settings[@]}"} build 2>&3)
  build_status=$?
  echo "$out" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u | head -40
  if grep -qiE 'No Accounts|Failed to load credentials' <<<"$out"; then
    echo "Xcode account access failed: stop, do not retry; ask the person to unlock and check Xcode Settings > Accounts (docs/ops/signing.md)" >&2
    exit 78
  fi
  if [ "$build_status" -ne 0 ] && grep -q 'Timed out waiting for all destinations' <<<"$out" \
    && grep -q 'needs to be unlocked' <<<"$out"; then
    echo "$(awk '{print $1}' <<<"$dest_line") is locked: unlock it and deploy again (nothing was built or installed)" >&2
    exit 79
  fi
  [ "$build_status" -eq 0 ] || { echo "build failed: nothing installed" >&2; exit "$build_status"; }
  grep -q "BUILD SUCCEEDED" <<<"$out" || { echo "build failed: nothing installed" >&2; exit 1; }
fi

status=0
while read -r name id udid type; do
  if ! run xcrun devicectl device install app --device "$id" "$product" >"$tmp/install" 2>&1; then
    if grep -q -i -E 'profile|0xe8008012|not.*(included|registered)' "$tmp/install"; then
      echo "== $name: not in the provisioning profile; run: scripts/deploy-all.sh $app --register $name"
    else
      echo "== $name: install failed: $(grep -m1 -i error "$tmp/install" | cut -c1-140)"
    fi
    status=1
    continue
  fi
  if run xcrun devicectl device process launch --device "$id" "$bundle" >"$tmp/launch" 2>&1; then
    echo "== $name: installed and launched$([ "$dry" = 1 ] && echo " (dry run: nothing was)")"
  elif grep -q -E '10002|could not be, unlocked|locked' "$tmp/launch"; then
    echo "== $name: installed; launch refused while locked (10002), it opens when unlocked"
  else
    echo "== $name: installed; launch failed: $(grep -m1 -i error "$tmp/launch" | cut -c1-140)"
  fi
done <<<"$phones"

if [ "$watch" = 1 ]; then
  [ -n "$watch_app" ] || { echo "--watch: no \"watch_app\" in the build object" >&2; exit 2; }
  while read -r name id udid type; do
    if run xcrun devicectl device install app --device "$id" "$watch_app" >"$tmp/watch" 2>&1; then
      echo "== $name: watch app installed"
    elif grep -q -E '1011|4000|usage assertion|timed out|Timeout' "$tmp/watch"; then
      echo "== $name: the watch is asleep (not on the wrist and awake); install again when it is"
    else
      echo "== $name: watch install failed: $(grep -m1 -i error "$tmp/watch" | cut -c1-140)"; status=1
    fi
  done < <(awk '$4 == "appleWatch"' "$tmp/all")
fi
exit $status

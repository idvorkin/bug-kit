#!/usr/bin/env bash
# Publish a built, development-signed .app to the over-the-air builds folder (the Cockpit's /builds page), so the
# page is never behind what was just installed on a device. It packages the very bundle the install used, so no
# second build or signing runs. The page writes the install manifest itself from the ipa's Info.plist: only the ipa
# goes. See docs/ops/deploying.md "Over the air".
#
#   scripts/ota-upload.sh <App.app> --name <prefix> [--repo <checkout>] [--built-dirty 0|1] [--force] [--dry-run]
#
#   --name     the file's prefix: <prefix>-<sha8>.ipa (grabber, ea, …)
#   --repo     the checkout it was built from: turns the bundle's short commit into 8 characters, and is the fallback
#              when the bundle names no commit (BugKitCommit, GitSha or BUGKIT_COMMIT in its Info.plist)
#   --built-dirty  whether the tree had uncommitted changes when it was built, for a bundle whose commit carries no
#              -dirty marker (GitSha); without it, --repo's checkout is asked at upload time
#   --force    copy even when the folder already has that file (otherwise it is only touched, so it sorts newest)
#   --dry-run  say what it would publish; copy nothing
#
# Where: OTA_HOST and OTA_DIR, else "ota": {"host", "dir"} at the top of ~/.config/bug-kit/apps.json
# (BUG_KIT_CONFIG). Neither: it says so and exits 0, publishing nothing. OTA_UPLOAD=0 turns it off.
# A build from uncommitted changes is published as <prefix>-<sha8>-dirty.ipa, replacing the last one of that name, so
# it never passes for the clean commit. Each run appends one line to ~/tmp/agent/notes/ota-uploads.log.
# Exits: 0 published, already there, or nowhere configured; 64 usage; 66 not a signed device build; 1 the copy failed.
set -uo pipefail
app="" name="" repo="" built_dirty="" force=0 dry=0
usage() { echo "usage: ota-upload.sh <App.app> --name <prefix> [--repo <dir>] [--built-dirty 0|1] [--force] [--dry-run]" >&2; exit 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || usage; name=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    --built-dirty) [ $# -ge 2 ] && [[ "$2" =~ ^[01]$ ]] || usage; built_dirty=$2; shift 2 ;;
    --force) force=1; shift ;;
    --dry-run) dry=1; shift ;;
    -h | --help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "ota-upload: unknown option $1" >&2; exit 64 ;;
    *) app=$1; shift ;;
  esac
done
[ -n "$app" ] && [ -n "$name" ] || usage
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "ota-upload: --name must be letters, digits, . _ -" >&2; exit 64; }
log=${OTA_UPLOAD_LOG:-$HOME/tmp/agent/notes/ota-uploads.log}
note() { echo "ota-upload: $*"; mkdir -p "$(dirname "$log")" 2>/dev/null && echo "$(date '+%F %T') $name: $*" >>"$log" || true; }

[ "${OTA_UPLOAD:-1}" != 0 ] || { echo "ota-upload: off (OTA_UPLOAD=0)"; exit 0; }
config=${BUG_KIT_CONFIG:-$HOME/.config/bug-kit/apps.json}
host=${OTA_HOST:-$(jq -r '.ota.host // empty' "$config" 2>/dev/null)}
dir=${OTA_DIR:-$(jq -r '.ota.dir // empty' "$config" 2>/dev/null)}
[ -n "$host" ] && [ -n "$dir" ] || { note "no OTA_HOST/OTA_DIR and no \"ota\" in $config; nothing published"; exit 0; }
dir=${dir#\~/}

app=${app%/}
info=$app/Info.plist
[ -f "$info" ] || { note "no $info: not an app bundle"; exit 66; }
[ -f "$app/embedded.mobileprovision" ] || { note "$app has no embedded.mobileprovision: not a signed device build"; exit 66; }

# The commit the bundle says it was built from, else the checkout's.
commit="" marked=0
for key in BugKitCommit GitSha BUGKIT_COMMIT; do
  commit=$(plutil -extract "$key" raw "$info" 2>/dev/null) && [ -n "$commit" ] && { [ "$key" = GitSha ] || marked=1; break; }
  commit=""
done
dirty=0
case $commit in *-dirty) dirty=1; commit=${commit%-dirty} ;; esac
[ "$marked" = 1 ] || [ -z "$built_dirty" ] || dirty=$built_dirty
if [ -z "$commit" ] && [ -n "$repo" ]; then
  commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || commit=""
  [ -z "$commit" ] || note "the bundle names no commit; using $repo's HEAD"
fi
[[ "$commit" =~ ^[0-9a-f]{4,40}$ ]] || { note "can't tell which commit $app was built from (no BugKitCommit/GitSha, no --repo)"; exit 66; }
if [ -n "$repo" ] && full=$(git -C "$repo" rev-parse --verify --quiet "$commit^{commit}" 2>/dev/null); then
  commit=$full
  [ "$marked" = 1 ] || [ -n "$built_dirty" ] || [ "$full" != "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" ] ||
    [ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=1
fi
sha=${commit:0:8}
file=$name-$sha$([ "$dirty" = 1 ] && echo -dirty).ipa
published=$dir/$file

remote=(ssh -o BatchMode=yes -o ConnectTimeout=15 -- "$host")
q() { printf "'%s'" "${1//\'/\'\"\'\"\'}"; }
if [ "$dry" = 1 ]; then
  echo "ota-upload: dry run: would package $app as $host:$published"
  exit 0
fi
if [ "$dirty" = 0 ] && [ "$force" = 0 ] && "${remote[@]}" "test -f $(q "$published")" 2>/dev/null; then
  "${remote[@]}" "touch $(q "$published")" >/dev/null 2>&1 || true
  note "$file already on $host (touched, so it sorts newest)"
  exit 0
fi

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Payload" || exit 1
# ditto keeps the signature's symlinks and resource forks as codesign left them; zip -y stores symlinks as links.
ditto "$app" "$tmp/Payload/$(basename "$app")" || { note "can't copy $app"; exit 1; }
(cd "$tmp" && zip -qry -X pkg.ipa Payload) || { note "can't zip $app"; exit 1; }
sum=$(shasum -a 256 "$tmp/pkg.ipa" | cut -c1-16)
size=$(($(stat -f %z "$tmp/pkg.ipa") / 1048576))
stage="$dir/.$file.$$.$RANDOM.part"
t0=$(date +%s)
if ! scp -q -o BatchMode=yes -o ConnectTimeout=15 -- "$tmp/pkg.ipa" "$host:$stage" ||
  ! "${remote[@]}" "mv -f -- $(q "$stage") $(q "$published")"; then
  "${remote[@]}" "rm -f -- $(q "$stage")" >/dev/null 2>&1 || :
  note "the copy of $file to $host failed; nothing replaced"
  exit 1
fi
note "$file -> $host:$published ($size MB, sha256 $sum, $(($(date +%s) - t0)) s)"

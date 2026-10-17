# Building and deploying to the phone, the iPad and the watch

## The device build

Every app's device recipe has this shape: EA `build-device` and `run-device`, CG `native-build-device`, MM `just ipad`.

The whole run, from generation to launch, holds the signing lock; the guard wraps only the build, and the
install starts only after the guarded build succeeded:

```sh
mkdir -p ~/tmp/agent/locks
lockf -k -t 900 ~/tmp/agent/locks/xcode-signing.lock scripts/device.sh   # the app's recipe body, below
```

```bash
#!/usr/bin/env bash
# scripts/device.sh: runs under xcode-signing.lock; never takes it again
set -uo pipefail
xcodegen generate || exit 1            # if the project is generated: after any project.yml change, or the build uses the old one
out=$("$BUG_KIT/scripts/signing-guard.sh" \
  xcodebuild -project App.xcodeproj -scheme App -derivedDataPath Build \
  -destination "platform=iOS,id=<udid>" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build)   # the guard's own messages stay on stderr
build_status=$?
echo "$out" | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
[ "$build_status" -eq 0 ] || exit "$build_status"   # including 78, account loss: never install or retry
echo "$out" | grep -q "BUILD SUCCEEDED" || exit 1
xcrun devicectl device install app --device <id> Build/Build/Products/Debug-iphoneos/App.app || exit 1
xcrun devicectl device process launch --device <id> <bundle-id>
```

- **`-allowProvisioningUpdates` lets Xcode create and refresh profiles. `-allowProvisioningDeviceRegistration` lets it add a new device to the team.** Every device recipe passes both.
- **Never pass `-sdk`.** It breaks the watch target (EA).
- **Run device builds with the sandbox off.** Provisioning needs it.
- **Quote product paths.** Some contain spaces (`Magic Monitor.app`).
- **Bake the commit into the app** with build settings (`BUGKIT_COMMIT=$(git describe --always --dirty --exclude='*')`), so reports and About say which build is running. `--dirty` keeps a build from uncommitted changes from passing for a clean commit (MM). In `deploy-all.sh`'s config that is `"BUGKIT_COMMIT={describe}"`.

## A failed build must not install the old one

The recipe above captures the guarded build's output, which the guard merges with the build's stderr, and
requires both a zero status and "BUILD SUCCEEDED" before the install. Don't add `2>&1` to the capture: it would
also swallow the guard's own "Mac is locked; waiting" and "build not started" messages.

- **`xcodebuild … | grep BUILD` alone exits 0 on "BUILD FAILED".** The next step then installed the previous bundle (EA #43). The same holds for `swift test | tail`: use `pipefail` (EA #51).
- **A failed install must not go on to launch the copy already on the device** (MM).
- **The same holds for a Mac tool built with `swift build` and then run.** A failed build leaves the last good
  binary in `.build/`, and the recipe runs it on the new input as if nothing had happened (EA #51). Capture and
  require "Build complete":

  ```bash
  out=$(swift build -c release --product tool 2>&1)
  echo "$out" | grep -E "error:|Build complete" || true
  echo "$out" | grep -q "Build complete" || exit 1
  .build/release/tool …
  ```

## Save the evidence before any relaunch

- **A relaunch destroys evidence.** A new launch starts a new log, and an app with a rolling buffer (video segments,
  an in-memory ring) prunes or drops what the person was just looking at. At MM, a relaunch once wiped 4 minutes of
  video, and a bare `pkill` wiped 7 more (mmn-1ui).
- **So every recipe that quits, kills or reinstalls the app first copies the newest session log and the buffer** to
  a timestamped folder, e.g. `~/tmp/agent/<app>/captures/<yyyyMMdd-HHmmss>/`. Print the wall-clock span the copy
  covers. MM's `_quit-app` runs `scripts/grab.sh 300` (the last 5 minutes) before every relaunch.
- **The same command runs on demand** (`just grab [secs]`) when the person says "that just happened". With
  `SessionLog(clocks: [.wall])`, `scripts/log-tool.sh around <log> HH:MM:SS` then slices the log at that time.
- **On a device**, `deploy-all.sh` installs over the running app. Run `pull-reports.sh <app>` first when a session
  is in progress.
- The copy itself is per app (which buffer, which folder). The rule is the shared part.

## One signing build at a time

Never run two `-allowProvisioningUpdates` builds at the same time on one Mac, across all agents.

- **The cause of the repeated account losses:** [BugKit #53](https://github.com/idvorkin/bug-kit/issues/53)
  traced them to provisioning builds while the Mac was locked: keychain reads fail and Xcode discards the
  account. Keep serialization, and also use the [screen-lock guard](signing.md#no-provisioning-builds-while-the-mac-is-locked).
- **The lock:** wrap the whole run, from project generation to launch, in a kernel lock. Inside it, the guard
  wraps the build only, so its account-loss check finishes before anything installs (see
  [the device build](#the-device-build)):

  ```sh
  mkdir -p ~/tmp/agent/locks
  lockf -k -t 900 ~/tmp/agent/locks/xcode-signing.lock <the device recipe: generate, guarded build, install, launch>
  ```

  - `lockf(1)` holds the lock for the life of the command, so no lock goes stale.
  - `-k` keeps the file, so a waiter never locks one that was just removed.
  - `-t 900` gives up after 15 minutes.
  - MM adopted this after a process check alone let two runs in together (mmn-af8). EA and CG still need to adopt it; `deploy-all.sh` does it for them.
- **Inside the lock, also wait for signing builds that did not take it,** using an anchored pattern:

  ```sh
  pgrep -fl '^[^ ]*xcodebuild .*-allowProvisioningUpdates'
  ```

  A bare `pgrep -f xcodebuild` also matches other agents' shells that merely mention the word. It once counted 30 "builds" and held a build for 20 minutes. To ask whether any xcodebuild is running at all, use `pgrep -x xcodebuild`.
- **Don't run a simulator test while a signing build runs** (EA). Its waits fail under contention, and a check can read the previous result.

## Build once, install everywhere

`scripts/deploy-all.sh <app>` does this:

1. It takes the lock.
2. It waits for any unlocked signing build.
3. Inside the signing lock, it waits for Mac unlock and prevents display sleep while building once, for the
   first device. Account-access errors stop the run without retrying or installing.
4. It installs and launches on each paired iPhone and iPad.

It needs a `build` object in the app's entry in `~/.config/bug-kit/apps.json` (see `listener/apps.example.json`).

What happens on each device:
- **Locked device:** a launch refused while the device is locked (CoreDeviceError 10002, "could not be, unlocked") is a soft success. The app is installed and opens when unlocked. Report it that way and don't rebuild.
- **Device locked at build time:** the build's destination device (the first one, or `--register`'s) must be unlocked while `xcodebuild` waits for it, or it times out with "The device needs to be unlocked to continue". The script then exits 79 with "<device> is locked: unlock it and deploy again" instead of reporting a build failure. Nothing was built; unlock the device and run it again.
- **New device:** a device not yet in the provisioning profile fails to install a build made for another device. Run one build with that device as the destination, with the Xcode account signed in: `deploy-all.sh <app> --register <device>`. After that the cached profile lists it. CG registered an iPad this way on 2026-10-07. See [signing.md](signing.md).
- **The watch:** the watch app is embedded in the phone build (`App.app/Watch/AppWatch.app`), so `--watch` installs it from the same product. The watch takes an install only when it is on the wrist and awake. Errors 1011 or 4000, a "usage assertion" failure, or a timeout mean it is asleep, not that the build is bad. Say so instead of retrying.
- **Unverified:** that one `Debug-iphoneos` product installs on every device already in the profile. It follows from how automatic signing embeds the team profile, but no repo had done it in a script before `deploy-all.sh`, and `deploy-all.sh` has only been dry-run.

## Destination errors

- **"destination not found"** means the device is not on the network or not paired. Unlock it and retry; it is not a signing problem.
- **`devicectl` needs no Apple account.** Installing and launching keep working when signing does not.

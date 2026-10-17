# Simulator lessons

## One named simulator, headless, one at a time

- **Give each repo or task its own simulator, booted headless, and never use `open -a Simulator`.** Delete throwaway simulators when done.

  ```sh
  xcrun simctl create <repo>-ipad <device-type>
  xcrun simctl bootstatus <udid> -b
  ```

- **One simulator on the Mac at a time** (see [runners.md](runners.md)).
- **Claim a named simulator through `mkdir -p ~/tmp/agent/locks && lockf -k -t 3600 ~/tmp/agent/locks/build.lock scripts/with-simulator.sh <name> -- <command>`.** Two agents that both see an empty booted list can otherwise claim the same simulator. The script holds a `lockf` lock per name (`~/tmp/agent/locks/sim-<name>.lock`), which stops two runs claiming the same simulator; the shared build lock stops two simulators booting across names. When an outer driver already holds `build.lock`, call the script without it. The script then waits until no simulator is booted, this one included, since a caller outside the lock may be using it (only a backstop for callers outside the build lock, not a guarantee), fails with 69 if `simctl` cannot list booted simulators, boots this one, runs the command with `SIM_UDID` set and shuts the simulator down on exit, pass or fail. The shutdown is retried three times and checked against the booted list; if the simulator stays booted, the script prints the `xcrun simctl shutdown <udid>` to run by hand and turns a passing run into exit 70 (a failing command keeps its own status). It exits 75 when the name or another simulator stayed busy for the whole `--wait` (default 1200 s). Create the command's log files inside the command, not before it, so two runs' logs cannot interleave (CG #298).
- **Resolve names to UDIDs.** Every Xcode update leaves a second "iPhone 17" behind on the older runtime, so a boot by name and a launch by name can land on different devices (EA and CG `sim-udid.sh`):

  ```sh
  xcrun simctl list devices available | grep -F -- "    $name (" | tail -1 | grep -oE '[0-9A-F-]{36}'
  ```

  `tail -1` picks the newest runtime, which is listed last.
- **Boot explicitly before `xcodebuild test`** when other simulators are up. Otherwise the test dies with "Timed out trying to boot simulator after 60 s".
- **Rerun before believing a first-run failure.** The first run on a just-made simulator can stall about 11 s before its first frame (MM).

## Driving the app without tapping

- **Launch hooks.** Use `SIMCTL_CHILD_<APP>_<ACTION>=… xcrun simctl launch <udid> <bundle>`. simctl strips the prefix, so the app reads `<APP>_<ACTION>`.
  - BugKit's `launchHookPrefix` gives `<APP>_BUG`, `<APP>_BUG_AFTER` and `<APP>_SHAKE_AFTER`.
  - EA has about 30 `SWING_*` hooks.
- **Wait for an event in the new launch's log, not a fixed time.** Remember the newest log before the launch and require a different file. Treat a timeout as a failure even if old data would match.
- **Privacy prompts:** `xcrun simctl privacy <udid> grant photos|microphone|location|location-always <bundle>`.
  - There is no camera service, and the simulator has no camera.
  - HealthKit's sheet cannot be granted from simctl. CG taps it once per simulator from a UI test.
- **Deep links:** open them from an XCUITest (`XCUIApplication().open(url)`). `simctl openurl` stops at an "Open in…?" prompt no script can answer.
- **Services the simulator lacks:** use one environment variable to point the app at a plain stand-in. EA's `SWING_SYNC_DIR` stands in for the iCloud container, and two simulators sharing it test sync end to end.

## A smoke script on `scripts/smoke-lib.sh`

Each app keeps its own checks. The plumbing is shared: source `scripts/smoke-lib.sh` from the BugKit checkout.

| Helper | What it does | From |
|---|---|---|
| `launch APP_BUG=x …` | terminates, remembers the newest log, launches with `SIMCTL_CHILD_` hooks | EA, CG |
| `wait_for <type> <secs>` | waits for an event in a log newer than the launch; a timeout fails the run | EA `sim-smoke.sh` |
| `require_event <type> [jq] [label]` | this launch's log has the event; `require_event selftest_finished` is the finish marker | MM's selftest |
| `fail_on_errors [label]` | any `error` event in this launch's log fails the run, naming `where` and `message` | CG `sim-smoke.sh` |
| `stash <paths>` / `unstash` | moves Documents paths aside and back, also on exit or Ctrl-C; a stash a killed run left is put back first | EA |
| `run <check> …` | runs the check unless `ONLY=<substring>` excludes it | EA |
| `smoke_done` | prints the result and exits 1 on any failure | |

- **A scripted flow logs that it finished** (`selftest_finished`, or the app's own name for it) as its last line. A
  crash or an early quit then fails the run instead of passing with whatever was logged before it (MM).
- **Any `error` event fails the run**, even when the feature under test passed. BugKit logs every failed step as
  `error`, and this gate turns those into failures (CG).

## Preferences: plist edits need cfprefsd restarted

- **For a key the app has never written,** use `xcrun simctl spawn <udid> defaults write <bundle> <key> <value>`. The app reads it.
- **For a key the app has already written,** that write is silently ignored, because the app's container plist wins.
- **Editing that plist alone is not enough either.** The simulator's cfprefsd keeps the domain cached after the app quits, so it does not read the edit, and the app's next save writes the cached keys back over it (EA PR #216).

What works:

```sh
prefs="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)/Library/Preferences/$BUNDLE.plist"
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
[ -f "$prefs" ] || { mkdir -p "$(dirname "$prefs")"; plutil -create xml1 "$prefs"; }
plutil -replace <key> -bool true "$prefs"              # -date, -string, … per type
xcrun simctl spawn "$SIM" launchctl kill SIGTERM system/com.apple.cfprefsd.xpc.daemon || true
sleep 1
xcrun simctl launch "$SIM" "$BUNDLE"
# afterwards: plutil -remove <key> "$prefs", and the same cfprefsd restart
```

A check deletes what it set. One hook's mode leaked into later launches until it did (EA #57).

## First-run state: erase needs shutdown

- **Reset a simulator to first-run state** with `xcrun simctl shutdown <udid> && xcrun simctl erase <udid>`. Erase refuses a booted simulator.
- **`simctl uninstall` fails on a shut-down simulator and leaves the old settings behind.** A test once failed because a previous run's "seen" setting survived a silently failed uninstall (CG).

## Other mechanics

- **Waiting for the app to exit:** capture `jobs=$(xcrun simctl spawn "$sim" launchctl list)` first, then grep the variable. Piping straight into `grep -q` under `pipefail` ends the wait early, which once looked like a crash (MM).
- **Screenshots:** `xcrun simctl io <udid> screenshot out.png`. Delete the old file first, so a previous run's picture cannot pass for this one.
- **App container:** `xcrun simctl get_app_container <udid> <bundle> data`.
- **App log:** `xcrun simctl spawn <udid> log show --predicate 'subsystem == "<subsystem>"' --info`.
- **Order-sensitive UI tests:** a test that hands off to Safari can break the next test in the same run. Run it alone.
- **Speed:** the simulator runs Core ML on the CPU, about a tenth of the phone's speed. Wait on events, not on time.
- **Fresh worktrees:** a fresh worktree lacks gitignored model files, so the app launches with no model and every check times out.
- **Watch simulators:** WatchConnectivity's `transferUserInfo` does not cross between paired simulators. To stage a lost phone, shut the phone simulator down; terminating the app is not enough, because watch messages relaunch it.

## Real data on the simulator

Host fixtures check the logic. A screen that shows real data needs the data on the simulator (CG):

1. Copy the real export into the container: `cp fixture.db "$(xcrun simctl get_app_container <udid> <bundle> data)/Documents/import-fixture.db"`.
2. Launch with an import hook, for example `SIMCTL_CHILD_<PREFIX>_IMPORT_DB=import-fixture.db,recent`.
3. **`recent` shifts every timestamp by whole weeks,** so the newest point lands in the last seven days. Screens that show "this week" or "today" then always have data, whenever the test runs. Whole weeks keep weekdays and times of day as they were.
4. Assert exact counts against the source of truth (CG compares with its older TypeScript import), and that a second import adds nothing.
5. A UI test that needs the fixture `XCTSkip`s with the copy command when it is missing, and undoes its own changes, so it can run twice.

The import hook is per app. The week shift is the part that is easy to miss.

## Screenshots for layout

Log events cannot show a tile's width or an iPad's landscape layout. Two cheap ways to see it on every run:

- **One screenshot per fixed state.**
  - The app takes a `<PREFIX>_STATE=<name>` launch hook and opens straight into that state.
  - A script launches each state once and takes `simctl io <udid> screenshot <state>.png`.
  - EA's `watch-screens.sh` shoots eighteen watch states and compares each against the control list at the top of its watch story.
  - Delete the old files first.
- **Named screenshots from UI tests, only when asked.**
  - XCUITests write PNGs (`home-today.png`, `whats-new-links.png`) at the moments that matter, into the folder named by `$<PREFIX>_SHOTS`. Unset, they write nothing.
  - Pass the variable as `TEST_RUNNER_<PREFIX>_SHOTS=<dir> xcodebuild … test`: xcodebuild strips `TEST_RUNNER_` for the test runner, as simctl strips `SIMCTL_CHILD_` (CG's `GRABBER_SHOTS`).
  - A green run then leaves pictures for a person, or for an agent that reads images, to check.

Screenshots show the person's data. They stay on the Mac and never go into a public repo or an issue (principle 13).

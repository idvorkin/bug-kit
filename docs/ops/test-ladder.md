# The test ladder

Verify every change on the cheapest rung that can see it, and **name the rung** in the commit, the issue comment and the handoff, for example "verified on the simulator, not on the phone". An unnamed rung makes the next session verify it again.

| Rung | Cost | What it sees |
|---|---|---|
| Host | about 1 s | Pure logic in a Swift package: `swift test` |
| Mac lab | seconds | The real model or pipeline on recorded input on the Mac (EA `just analyze clip.mov`; MM `just selftest` on a clip) |
| Simulator | minutes | The app running: launch hooks, assertions on the session log |
| Device | a human | Camera, sensors, signing, real iCloud, the feel |

## Rules

- **Put logic in a Swift package** so the host rung can see it. BugKit itself does this: the report format, the store, the dialog's flow, the shake gesture, log retention and What's new are host-tested, and only the views are not.
- **Simulator checks assert on log events** (`jq` over the session log), not on screenshots or UI automation. Layout is the exception, since no event shows it: take one named screenshot per state and read them by eye (see [simulators.md](simulators.md#screenshots-for-layout)).
- **A wrong result from data gets a fixture first.** Turn the recorded input into a host test that fails, then fix the code. Never tune by reinstalling (EA).
- **Keep long test reports in a file.** SwiftPM caps a test's stdout and silently cuts long reports.
- **Close issues only after the verifying rung has run.** Use `Fixes #N` in the commit when that rung already ran; otherwise close by hand once the build is on the device. Either way, name the rung and the log line that proves the fix, for example `watch_inbox stuck 14 recovered 2` (EA #197), and say what the person should feel.
- **Swift Testing with only the Command Line Tools:** the macro plugin can fail about 2 builds in 3 with "plugin for module 'TestingMacros' not found". Pass `-Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib` (MM).

## The rungs in each app

| | Host | Mac lab | Simulator | Device |
|---|---|---|---|---|
| EA | `just test` | `just analyze` | `just test-sim`, plus `just watch-screens` | `just run-device`, then `just pull-logs` |
| CG native | `just native-test` | none | `just native-test-sim` | `just native-run-device`, then `just pull-logs` |
| MM | `just test` | `just selftest` | `just ipad-selftest` | `just ipad` |
| BugKit | `swift test`, plus the listener's pytest; on Linux, `just test-linux` | none | none of its own; an app's simulator checks use the launch hooks | an app that has migrated |

## What kind of change goes on which rung

Each app keeps a table with one row per kind of change: the rung that must see it, and the test or event that shows it, by name. It stops a session from verifying a HUD change on the host, or an analyzer change on the phone. EA's `docs/TESTING.md` "What kind of test goes where" is the model. A few of its rows:

| Change | Rung | How |
|---|---|---|
| Analyzer thresholds, rep rules | Host | the fixture's count, pinned in a test |
| Offline pass, import, wiring in the app | Simulator | `check <clip> <exercise> <reps>` in the smoke script |
| Player, overlay, HUD, layout | Simulator screenshots, then the phone | the screenshot script, read by eye; the phone for HDR |
| Camera, recorder, idle timer | Phone only | record a set, pull the logs, check `camera_*` and `error` events |
| Watch companion | Phone and watch | `watch_session`, and `ui` events with `from: watch` |

A row names the event or test, never just "check it works". When a change fits no row, add the row in the same commit.

# BugKit

Bug reports, session logs and crash evidence for iOS apps, plus opt-in private CloudKit delivery and a Mac listener that pulls reports from CloudKit or paired iPhones and iPads and files them in GitHub, beads or a local inbox.

BugKit requires **iOS 17+**. Its report model, storage and flow also support **macOS 14+**, and the model, store, writer, CloudKit sender and a watch report form (`WatchBugReportView`) build for **watchOS 10+**; the shake and sheet reporting UI is iOS only. Building the package’s tests requires **Swift 6+** because they use Swift Testing.

- Shake, tap a button or press ⌘I to report a problem. The dialog captures a screenshot before opening and supports “Log it and another.”
- Each report carries a UUID, build, typed context, session log path and timestamp. Default files stay in app-container Documents on iOS/watchOS and app-specific Application Support on macOS; explicit directories remain supported. Optional CloudKit delivery uploads an immutable evidence copy.
- The listener polls paired iPhones/iPads and configured local Mac stores, files reports once and names local screenshot paths without uploading images. Set an app's `mac_dir` to its storage root; see [local Mac configuration](docs/ops/listener.md#local-mac-apps).
- An optional What's new feed connects git commits to user stories and shows recent changes on iOS and macOS.

Extracted from Exercise Analyzer, Context Grabber and Magic Monitor so shared fixes reach every app.

## Shared practices for every app

BugKit is the one repository every app shares, so it also holds practices each app should follow even when they are not
BugKit code. They live here because this is the global repo, not because they depend on the library:

| Practice | Where |
|---|---|
| Building, signing, deploying and testing on real devices with agents | [docs/ops](docs/ops/README.md) |
| Evidence, deduplication, crashes and debugging | [docs/principles.md](docs/principles.md) |
| Fixing a shared bug once, here, not in each app | [Where a bug gets fixed](#where-a-bug-gets-fixed) |
| The app checklist: report a problem, What's new, version and commit, session logs, crash capture, CloudKit opt-in | [docs/app-checklist.md](docs/app-checklist.md) |

Link to this section from each app's AGENTS.md. When work in one app turns up a bug or a practice that applies to every app,
file it here and link the app's issue to it.

## Quick start

Add `https://github.com/idvorkin/bug-kit` through Xcode’s **File › Add Package Dependencies**, and link the `BugKit` product. With XcodeGen:

```yaml
packages:
  BugKit:
    url: https://github.com/idvorkin/bug-kit
    exactVersion: 0.3.11  # an exact tag, never main
targets:
  MyApp:
    dependencies:
      - package: BugKit
```

Create one reporter at launch and attach it to your root view. This minimal app uses BugKit’s session logger:

```swift
import BugKit
import SwiftUI

@main
struct MyApp: App {
  @StateObject private var reporter: BugReporter
  private let log: SessionLog

  init() {
    let log = SessionLog(prefix: "app")
    self.log = log
    CrashReports.shared.install(logger: log.logger)
    BugStore().pruneLogs(logger: log.logger)
    let options = BugReporterOptions()  // rich diagnostics are on; `options.richDiagnostics = false` turns them off
    _reporter = StateObject(wrappedValue: BugReporter(
      hooks: BugReporterHooks(
        screen: { "home" },
        sessionLog: { log.position },
        logger: log.logger,
        flushLog: { log.flush() }
      ), options: options
    ))
  }

  var body: some Scene {
    WindowGroup {
      NavigationStack {
        Text("My app")
          .toolbar { BugReportButton(reporter: reporter) }
      }
      .bugReporting(reporter)
    }
  }
}
```

Rich diagnostics are on by default: each report gets recent interaction breadcrumbs and a public view/accessibility snapshot, and `options.richDiagnostics = false` turns both off. See [UI diagnostics](docs/integration.md#interaction-and-accessibility-diagnostics) for coverage and semantic action hooks.

See [integration](docs/integration.md) for context, extra files, dictation, simulator hooks and What's new. Dictation is off by default; Apple Speech requires speech and microphone usage descriptions in Info.plist; a cloud provider needs the microphone description. Set `BugKitCommit` in Info.plist to include the app’s commit in reports.

## Enable each feature

Set options **before** constructing `BugReporter(hooks: ..., options: options)`, and keep `.bugReporting(reporter)` on your root view as in the quick start. Rich diagnostics (interaction breadcrumbs and the accessibility snapshot) are on by default; set `options.richDiagnostics = false` to turn both off.

### Clicks, touches and semantic actions

```swift
options.interactionLimit = 200  // recent events per report; clamped to 1...1,000
```

This records touches, approximate taps/drags/long presses, UIKit control actions and scene activity. Each report gets `interactions.jsonl`; events also go to your `logger` hook. For exact SwiftUI, keyboard or VoiceOver actions, add this to the relevant action handler:

```swift
reporter.recordInteraction("open_settings", fields: ["source": "keyboard"])
```

Give views stable identifiers, such as `.accessibilityIdentifier("settings-button")`, to make events easier to locate. Automatic capture observes the active app window; it does not capture every semantic action automatically.

### Accessibility tree dump

Each report gets `accessibility.json`, captured before the report dialog opens. It contains the public UIKit view/accessibility hierarchy, identifiers, labels, hints, frames and traits, bounded to 500 nodes and depth 30. Text-entry subtrees and accessibility values are omitted. Some virtual SwiftUI elements may be absent. It comes with interaction recording; `richDiagnostics = false` turns off both. See [coverage and limitations](docs/integration.md#interaction-and-accessibility-diagnostics).

### Crash capture and automatic filing

Install crash capture once at app launch, after creating the session logger:

```swift
CrashReports.shared.install(logger: log.logger)
```

Then configure the Mac listener using [Pull and file reports](#pull-and-file-reports) below and run:

```sh
listener/bug-listener --once --backfill  # first poll: include existing reports and crashes
listener/bug-listener                   # keep polling for new evidence
```

No separate listener flag is needed for crash discovery. It polls `Documents/crashes` even when no manual bug report exists; set `crash_dir` in the app's `apps.json` entry if your app uses another directory. Use `--backfill` before the first successful crash poll to include historical crashes, including after upgrading the listener.

### Setup checks and agent-readable status

After configuring `apps.json`, run these from the repository root:

```sh
listener/bug-listener doctor --json  # check config, tools, devices and tracker access
listener/bug-listener status --json  # read last poll, health and pending evidence
```

These commands need no feature flag. Run the listener at least once to populate status; keep it running for current results. `status` only reads local state. Omit `--json` for human-readable output. See [health checks and exit codes](docs/ops/listener.md).

### Other reporting features

| Feature | How to enable or configure it |
|---|---|
| Automatic app-triggered reports | Call `reporter.autoReport(reason: "call_failed", files: [callLog])`. Configure `options.auto.window` (600 seconds per reason) and `options.auto.maxBytes` (5 MB) before creating the reporter. No dialog or screenshot; see [automatic reports](docs/integration.md#automatic-reports). |
| Copyable error context | `options.copyableErrors` defaults to `true` for dictation errors. App error screens can use `BugProblem` and `BugProblemView`. |
| Wall and host-clock timestamps | Create `SessionLog(prefix: "app", clocks: [.wall, .mono])`. Both are off by default. |
| Memory on status lines | Use `log.status(every: 5, memory: true) { ... }` to include `rss_mb`. Default: off. |
| Bridge an existing logger | Convert fields with `fields.mapValues(\.foundation)` when the app's logger accepts `[String: Any]`. |
| Foundation context | Convert an existing `[String: Any]` context with `try context.mapValues { try JSONValue(foundation: $0) }`. Unsupported values throw `JSONValue.FoundationConversionError`; `BugReporterHooks.context` does not throw, so convert and handle the error before supplying it. |
| Apps with a keyboard extension | Link BugKit to the host target only. The model, store, writer and session log compile extension-safe; the reporter UI is unavailable in extensions. See [extensions](docs/integration.md#app-group-storage). |
| Private CloudKit delivery | Add the shared container entitlement, retain `CloudKitReportDelivery`, await `prepare(documents:)` before exposing the reporter/writer, pass `delivery:`, and call `start()` at launch/foreground. Only reports saved after opt-in upload. New adopters, `prepare(documents:)` and Mac apps pin `exact: "0.3.11"`; existing 0.3.0–0.3.2 senders without `prepare` remain compatible with the reader. Configure the listener with `cloudkit_config`. Default: off. See [CloudKit adoption](docs/integration.md#private-cloudkit-delivery). |
| Weekly usage summary | The listener appends one `kind: "usage"` line per app to `inbox.jsonl` every `usage_days` (default 7; `0` turns it off), from the `ui_*` breadcrumbs in pulled session logs. Set `"usage": false` on an app to skip it. `listener/bug-listener usage [--days N] [--json]` reads the logs already on the Mac. See [usage summary](docs/ops/listener.md#usage-summary). |
| Shake and keyboard reporting | Enabled by `.bugReporting(reporter)`. `systemShake`, `gentleShake`, `commandI` and `dialogKeys` default to `true`. |
| Report button | Add `BugReportButton(reporter: reporter)` to your view or toolbar. |
| Session log association | Create `SessionLog`, then supply `sessionLog: { log.position }`, `logger: log.logger` and `flushLog: { log.flush() }` hooks as in the quick start. |
| Copy the log into each report | Set `options.copySessionLog = true` with the session-log hooks above; adds `session.jsonl`. Default: `false`. |
| Standalone report metadata | Set `options.writeReportJSON = true` to add `report.json` beside attachments. Default: `false`; the main `bugs.jsonl` index is always written. |
| Dictate a note | Set `options.dictation = true` (default `false`). Apple Speech is the default and needs `NSSpeechRecognitionUsageDescription` and `NSMicrophoneUsageDescription` in Info.plist. |
| Select a microphone | With dictation enabled, open the report's “Microphone” menu, choose “Refresh microphones” to load the inputs (and grant initial mic permission), then select Automatic, built-in, USB/wired, or a headset iOS offers. The preference is kept for later reports; picks apply before dictation starts. Opening a report does not query inputs or retune audio. |
| Disable automatic screenshots | Set `options.captureScreenshots = false` (default `true`). Applies to the report sheet, recapture and launch-hook reports. For private-text apps, also set `richDiagnostics = false` (default `true`) and keep `dictation` off. [Privacy configuration](docs/integration.md#private-text-apps). |
| Input level and mic picker on any voice input | With dictation enabled the report dialog shows a live input level meter beside the microphone menu. Apps with their own mic button on `NoteDictation` add `BugVoiceInputControls(dictation:)` beside it; `NoteDictation.level` (a `DictationInputLevel`, `value` 0...1, about 20 Hz, 0 when not listening) and `BugInputLevelMeter(level:)` / `(value:)` are public. See [the controls](docs/integration.md#the-microphone-picker-and-input-level-on-every-voice-input). |
| Deepgram or another speech server | Set `hooks.dictationProvider` to a factory returning `DeepgramDictationProvider` or your own `BugDictationProvider`. Cloud providers need only the microphone usage description; the app owns credentials. See [voice input providers](docs/integration.md#voice-input-providers). |
| Remove a report screenshot | Tap the ✕ on the screenshot in “Attached automatically.” Enabled by default. The choice persists for `.keepMoment`; `.recapture` takes a fresh image. Context stays attached. |
| Fresh evidence for “Log it and another” | Set `options.another = .recapture`. The default `.keepMoment` reuses the captured screenshot and diagnostics. |
| App context and extra attachments | Supply the `context` and `extraFiles` hooks; see the [integration example](docs/integration.md). |
| Commit in reports | Set `BugKitCommit` in the app's Info.plist to its build's git commit. |
| Simulator launch hooks | Set `options.launchHookPrefix = "APP"` and call `reporter.runLaunchHooks()` on appearance. Launch with `SIMCTL_CHILD_APP_BUG="test note" xcrun simctl launch booted <bundle-id>` to save a report. Add `SIMCTL_CHILD_APP_BUG_AFTER=10` for slower cold launches (default 2 seconds), or use `SIMCTL_CHILD_APP_SHAKE_AFTER=2` to open the dialog. |
| Reset What's new for UI tests | Construct `WhatsNewSeen(launchHookPrefix: "APP", logger: logger)` once in app initialization and pass it to the row. Launch with `SIMCTL_CHILD_APP_WHATS_NEW_RESET=1`. This clears dismissal before the first home render. |
| About / version | Pin `exact: "0.3.11"`. Add `BugKitAboutLink()` inside Settings navigation; set build Info.plist keys `BugKitCommit` and `BugKitRepositoryURL`. Pass `extraRows` for model name/version; see [adoption](docs/integration.md#about--version-in-settings). |
| What's new | Add the `scripts/whats-new.sh` build phase, load `WhatsNewSeen.bundledFeed()`, then display `WhatsNewRow` / `WhatsNewView`; see the [complete setup](docs/integration.md). |
| Log retention | Call `BugStore().pruneLogs(logger: log.logger)` at launch. Add `keepNewest: 20` for a count cap; logs named by reports remain protected. |

For CloudKit troubleshooting, add `--diagnostics` to the signed Mac reader for local full-error inspection.
To check one report the listing omits, run the reader with `--fetch-report UUID`; see [the direct lookup](docs/integration.md#diagnose-a-report-missing-from-the-query).
The Development schema needs a `BugKitReport.recordName` Queryable index; see [setup](docs/integration.md#private-cloudkit-delivery).
Apps using dictation should adopt v0.3.2 to receive the fix for doubled partial/final transcripts.


For package updates, workarounds to remove, per-app options and downstream verification, see [adopting the merged features](docs/migration.md#adopting-the-merged-features). It covers Exercise Analyzer, Context Grabber and Magic Monitor separately.

For Debug symbolication, set Xcode’s `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` and keep the dSYM from the exact build that crashed. Xcode can place both the app stub and `<App>.debug.dylib` DWARF files in one `<App>.app.dSYM`; the script scans both. A Debug build without this setting may have no dSYM, in which case the script exits 2. Multiline watchdog reasons are printed as a single cause line.

For agent tools, use `scripts/log-tool.sh` to slice logs, `scripts/symbolicate.sh` with a matching dSYM, and `scripts/bugs-monitor.sh [app]` to watch report checks. Configure `pull_extra` in an app's config entry for extra paths copied by `pull-reports.sh`. Source `scripts/smoke-lib.sh` from app-specific simulator checks, and claim the simulator with `mkdir -p ~/tmp/agent/locks && lockf -k -t 3600 ~/tmp/agent/locks/build.lock scripts/with-simulator.sh <name> -- <command>` (drop the `lockf` when an outer driver already holds `build.lock`); see [simulator setup](docs/ops/simulators.md).

## Pull and file reports

The listener needs [uv](https://docs.astral.sh/uv/), Xcode’s `devicectl`, and paired devices. GitHub trackers also need authenticated `gh`; beads trackers need `bd`.

From the repository root:

```sh
mkdir -p ~/.config/bug-kit ~/tmp/agent/bugs
cp listener/apps.example.json ~/.config/bug-kit/apps.json
# Edit apps.json: app name, bundle ID, local repo and tracker.
listener/bug-listener doctor --json
listener/bug-listener --once --dry-run --backfill
listener/bug-listener --once --backfill
listener/bug-listener
# From another terminal:
listener/bug-listener status --json
```

**First contact matters:** without `--backfill`, the listener marks existing reports and crash files seen without filing them; for a GitHub-tracked app, reports that have no issue yet are filed instead (see [listener operations](docs/ops/listener.md)). The two streams have separate baselines, including when upgrading from a listener that did not discover crashes. Use `--backfill` on the first real poll to file existing evidence. A dry run copies files and writes logs, but leaves issues, seen-store, inbox and notifications unchanged.

Crash files are discovered on every poll, even without a manual report. Signal/exception crashes include the latest preceding session log when its start time is available; that association is explicitly marked as inferred. MetricKit payloads keep their crash/hang evidence without claiming an exact session.

Reports land under `~/tmp/agent/bugs/<app>/<device>/`. Failed copies of a report’s folder or named session log leave it pending for the next poll. Screenshots stay on the Mac; issue bodies contain their local paths.

Apps storing evidence in an App Group can pass the group's `Documents` directory to the store, log and crash capture, and set `app_group` in their entry in the apps config; the listener and `scripts/pull-reports.sh` (including `--check`) then copy from the group's container. See [App Group storage](docs/integration.md#app-group-storage).

See [listener setup](docs/ops/listener.md) for configuration, logging and launchd. For manual pulls and deployment:

```sh
scripts/pull-reports.sh                       # all configured apps and devices
scripts/pull-reports.sh --check               # devices and CloudKit; 1 unfiled, 2 lookup error, 3 listener stale
scripts/deploy-all.sh my-app --dry-run        # inspect the configured deployment commands
```

## Documentation

| Guide | Contents |
|---|---|
| [Integration](docs/integration.md) | Hooks, options, session logs, dictation and What's new |
| [Report format](docs/report-format.md) | JSON Lines keys and storage layout |
| [Principles](docs/principles.md) | Evidence, reporting, deduplication, crashes and debugging practices |
| [App migrations](docs/migration.md) | Historical feature matrix and EA, CG and MM migration checklists |
| [User stories](docs/stories/README.md) | Acceptance criteria and verification rungs |
| [Operations](docs/ops/README.md) | Pulling, filing, signing, deployment, runners and simulators |
| [App checklist](docs/app-checklist.md) | What every app that adopts BugKit sets up, each item linked to its doc |

## Where a bug gets fixed

**A bug in BugKit's code is fixed in BugKit, not in the app.** That covers the dialog, shake, dictation, the store
and its format, crash capture, pruning, What's new, the listener and the scripts. Every app shares one copy, so a
patch inside one app leaves the others broken and the copies drift apart, which is how three apps ended up with
three bug-report implementations.

1. File the issue here (idvorkin/bug-kit), quoting the app's report and log line. The app's issue links to it.
2. Fix it on a branch here, with a host test that fails before the fix. This is a public repo, so leave out
   personal data.
3. PR and merge, then bump the BugKit version in each app (its SPM reference) and redeploy.
4. Until the fix lands, an app may work around it through BugKit's hooks or options, never by copying BugKit's
   code in. Mark the workaround with a `ponytail:` comment naming the BugKit issue.

Example: Context Grabber's dictation reset (CG #249) was fixed here as PR #3, then picked up by each app.

A bug in the app's own hooks (its context, screen names, extra files, logger bridge) stays in the app.

## Developing BugKit

### Beads work tracking

Use Beads (`bd`) for agent task tracking. GitHub remains the intake for reports and the review surface for PRs; link related issues with `--external-ref <issue-url>`.

On a fresh clone, initialize the local database from this repo's existing task remote:

```sh
bd init --prefix bug --remote git+https://github.com/idvorkin/bug-kit.git \
  --non-interactive --skip-hooks --skip-agents
```

For an initialized checkout:

```sh
bd prime
bd dolt pull
bd ready
bd create "Describe the work" --type task --description "Why and acceptance criteria"
bd update <id> --status in_progress
# After implementing and validating the work:
bd close <id> --reason "What shipped and how it was verified"
bd dolt push
```

Create a bead before starting work and close it after completion. Worktrees share the main checkout's embedded Dolt database. Task data syncs with `bd dolt pull` and `bd dolt push`, separately from code commits and PRs; an ordinary Git push does not sync tasks. See [.beads/README.md](.beads/README.md); [AGENTS.md](AGENTS.md) defines the workflow and shared-simulator rules.

### no-mistakes validation

Every code or config change (including `.no-mistakes.yaml`, CI, entitlements and project settings) must pass no-mistakes before merge. The pipeline supplies the review as well as validation. Docs-only changes, such as README or docs text, a story Status line or a ledger row, skip it and are pushed straight to the branch on `origin`; see [AGENTS.md](AGENTS.md).

This repo uses [.no-mistakes.yaml](.no-mistakes.yaml) for targeted local validation and [.github/workflows/ci.yml](.github/workflows/ci.yml) for the full Swift/Python regression suite and iOS compilation on macOS. The local Test agent runs only host tests relevant to the change; simulator and device checks run once in the driving session and are recorded in the PR body.

On a new checkout, with `no-mistakes` installed and a supported agent configured:

```sh
no-mistakes init
no-mistakes doctor
# Commit the intended changes on a feature branch, then:
no-mistakes axi
no-mistakes axi run --intent "Describe the user's goal and constraints"
```

The run performs review, validation, documentation, push, PR creation and CI monitoring. Resolve any decision gates through `no-mistakes axi respond`; `no-mistakes axi status` shows progress. The repository's custom gate commands and instructions take effect after `.no-mistakes.yaml` is merged into the default branch. Initializing the local gate alone does not publish changes or configure GitHub branch protection.

### Manual checks

On a Mac with Swift 6+, uv and `jq` (used by the shell scripts):

```sh
swift test
uv run --python 3.12 --with typer --with pytest pytest --import-mode=importlib listener/ Tests/ scripts/tests/
for script in scripts/*.sh; do bash -n "$script"; done
```

Swift tests cover storage, concurrent writes, report flow, dictation merging, logs, crashes and What's new. Python tests cover listener parsing, deduplication, independent crash discovery, evidence retries, doctor/status JSON and deployment commands with fake tools.

With XcodeGen and a selected iOS simulator, run `scripts/test-ios-diagnostics.sh <simulator-udid>` to check accessibility redaction, traversal limits and control capture.

Host tests do not exercise the iOS UI. Typecheck it with an installed iOS SDK:

```sh
xcrun --sdk iphoneos swiftc -typecheck -swift-version 6 -target arm64-apple-ios17.0 \
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" Sources/BugKit/*.swift
```

For device verification, shake, save with “Log it and another,” then save a second note. Confirm the listener receives two reports with their evidence. Record whether a fix was verified on the host, in a simulator or on a device; see the [test ladder](docs/ops/test-ladder.md).

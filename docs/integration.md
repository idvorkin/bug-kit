# Integrating BugKit

[Back to BugKit](../README.md).

1. Add the package. In Xcode, use **File › Add Package Dependencies** with `https://github.com/idvorkin/bug-kit`.
   With XcodeGen, add this to `project.yml`:

   ```yaml
   packages:
     BugKit: { url: https://github.com/idvorkin/bug-kit, branch: main }
   targets:
     MyApp:
       dependencies: [{ package: BugKit }]
   ```

2. Set Info.plist `BugKitCommit: $(BUGKIT_COMMIT)` and pass the app's commit on the build command:
   `xcodebuild ... BUGKIT_COMMIT="$(git describe --always --dirty --exclude='*')" build`.
   This marks uncommitted builds `-dirty`. `deploy-all.sh` supports `"BUGKIT_COMMIT={describe}"` in
   `build.settings`. Without a supplied value, reports say "unknown".

3. At launch:
   - open the session log, if the app has none of its own;
   - install crash capture;
   - prune old logs;
   - create one reporter with the app's hooks and options, and attach it to the root view.

The example below uses your app’s `AppModel` and `ContentView`; adapt the hooks to your model.

```swift
import BugKit
import SwiftUI

@main
struct MyApp: App {
  @StateObject private var model: AppModel
  @StateObject private var reporter: BugReporter
  let log: SessionLog
  let whatsNew = WhatsNewSeen.bundledFeed()                            // whats-new.json from scripts/whats-new.sh

  init() {
    let log = SessionLog(prefix: "app", fields: ["build": "1.0 (42)"])
    self.log = log
    CrashReports.shared.install(logger: log.logger)        // MetricKit, signal and exception files, announced once
    BugStore().pruneLogs(logger: log.logger)               // logs older than 30 days, except reported ones
    let model = AppModel(log: log)
    _model = StateObject(wrappedValue: model)
    var options = BugReporterOptions()
    options.another = .keepMoment                          // or .recapture: a fresh picture for each report
    options.dictation = true                               // needs the speech and microphone usage strings
    options.privacyNote = "Nothing leaves this device until the developer pulls it."
    options.launchHookPrefix = "APP"                       // SIMCTL_CHILD_APP_BUG="a|b" in simulator checks
    _reporter = StateObject(wrappedValue: BugReporter(hooks: BugReporterHooks(
      screen: { model.screenName },                              // "home", "playback"
      context: { ["exercise": .string(model.exercise), "playhead": .double(model.playhead)] },
      sessionLog: { [log] in log.position },                     // ("logs/app-20261010-150000.jsonl", 84442)
      logger: log.logger,                                        // bug_report lands in the session log
      extraFiles: { folder in                                    // optional: e.g. the clip at the playhead
        try await model.exportClip(to: folder.appendingPathComponent("clip.mov"))
        // Window snapshots can omit video layers; render the playhead frame from the clip.
        try await model.writeFrame(to: folder.appendingPathComponent("frame.jpg"))
        return ["clip.mov", "frame.jpg"]
      },
      microphoneBusy: { model.inCall },
      flushLog: { log.flush() }), options: options))
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .bugReporting(reporter)  // shake (hard or gentle), or ⌘I on a hardware keyboard
        .onAppear { reporter.runLaunchHooks() }
    }
  }
}

// Anywhere a button is easier than a shake (an iPad on a stand):
BugReportButton(reporter: reporter)
// The home screen's What's new line, with its ✕, and the list it opens:
WhatsNewRow(feed: whatsNew, logger: log.logger) { showWhatsNew = true }
NavigationStack { WhatsNewView(feed: whatsNew, logger: log.logger) }
```

- `reporter.shakeEnabled = false` ignores shakes, for example during a run where the phone is in a pocket (EA
  story 037).
- `reporter.lastStatus` says "Problem logged. Thanks." after a save, for a status line.
- `log.status(every: 5) { [...] }` writes a periodic status line.
- Add `memory: true` to include resident memory (`rss_mb`); create the logger with `clocks: [.wall, .mono]`
  to include wall-clock and host-uptime timestamps. See [logging conventions](ops/logging.md).
- For an app-owned `[String: Any]` logger, use `{ type, fields in log.event(type, fields.mapValues(\.foundation)) }`.
- `WhatsNewRow` and `WhatsNewView` also build on macOS. The UIKit reporter remains iOS-only.
- `RecentSegments.covering(segments, now:, seconds: 90, start:, end:)` picks the recorded segments for `extraFiles`.

For Apple dictation, add `NSSpeechRecognitionUsageDescription` and `NSMicrophoneUsageDescription` to Info.plist before setting `dictation = true`. A cloud provider that does not require Apple Speech needs only the microphone usage description.

4. **What's new** is a build phase. With XcodeGen:

   ```yaml
   preBuildScripts:
     - name: What's new
       script: '"$BUILD_DIR/../../SourcePackages/checkouts/bug-kit/scripts/whats-new.sh" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/whats-new.json" --repo "$SRCROOT" --base-url "https://github.com/<owner>/<repo>/blob/main/docs/stories/"'
       basedOnDependencyAnalysis: false
   ```

   - It reads the last 30 days of `git log` and the stories in `docs/stories/`, in the "### User Story NNN:" and
     "- **Summary:**" form.
   - A commit counts when its subject starts with "Story NNN:", ends with "(story NNN)", names the story in its
     message, or names an issue that a story's Issues line lists.
   - Without git history it writes an empty feed and never fails the build.
   - The phase reads `.git` and writes into the bundle; the existing recipe sets
     `ENABLE_USER_SCRIPT_SANDBOXING: NO` on the app target.

## Automatic reports

Keep one reporter and invoke the failure hook only when the app's own check identifies a problem:

```swift
var options = BugReporterOptions()
options.auto.window = 600
options.auto.maxBytes = 5_000_000
// Pass options and flushLog to BugReporter at construction, then at a failure:
reporter.autoReport(reason: "call_failed", context: ["stage": .string("transcribe")], files: [callLog])
```

`autoReport` flushes the app's log hook, captures screen/log position, and schedules a save without a dialog or
screenshot. It does not await delivery. The saved report carries `source: "auto"` and `reason`; manual reports
omit both keys. A persistent per-reason window limits repeat triggers across relaunches. Use stable reason codes
so unique call IDs do not defeat the limit. Attachments share the configured byte budget, including
`session.jsonl` when `copySessionLog` is on (copied once, even if also passed in `files`); `report.json` and the
bugs.jsonl line are outside it. Oversized text logs keep their tail from a line start (`bug_report_auto_cut`); a
file that fails is logged as an `error` (`bug_auto_file`) and the rest are still attached; files with the same name
are kept as `call.jsonl`, `call-2.jsonl`. Manual reports still copy the whole session log. A Mac or Foundation-only caller can retain `BugAutoReporter(writer:options:)` and await
`report(reason:context:files:)`; provide its own logger flush before calling.

The updated Mac listener files an automatic report with a reason-based title and `bug,auto` labels (beads:
`from-app,auto`), deduplicated by report ID. If GitHub labels do not exist, filing retries without labels.
Delivery waits for a reachable device. Automatic reports do not implicitly capture the manual report's
interaction/accessibility snapshot; the manual diagnostic options below remain independent.

See [per-app adoption](migration.md#adopting-the-merged-features) before replacing a diagnostics gist or removing
an app's existing delivery path.

## Interaction and accessibility diagnostics

Enable the options when constructing the reporter:

```swift
var options = BugReporterOptions()
options.recordInteractions = true
options.captureAccessibility = true
options.interactionLimit = 200  // 1...1,000 events retained per report
```

Pass `options` to `BugReporter(hooks:options:)` and attach `.bugReporting(reporter)` to the app's root view. Both options default to false. Interaction events go to the existing logger and a bounded in-memory buffer. At report opening, BugKit freezes the buffer and the accessibility snapshot alongside the screenshot. `.keepMoment` reports reuse this evidence; `.recapture` takes a fresh snapshot. The report's log position now names the captured moment rather than the later save time.

The report folder gains `interactions.jsonl` and `accessibility.json`, also listed in the report's `files`. These files are independent of the app's `extraFiles` hook. Their contents stay local when the listener files an issue; the issue lists their paths.

| Event | Evidence |
|---|---|
| `ui_touch_begin` | Original hit view's class, nearest accessibility identifier, coordinates and touch type |
| `ui_tap`, `ui_drag`, `ui_long_press` | Approximate touch classification, displacement, duration and tap count |
| `ui_touch_cancel` | A touch sequence was cancelled |
| `ui_control` | UIKit primary actions and value changes; switch/slider/segment state where available |
| `ui_scene` | Whether the reporting view's scene is active |

The observer uses a [public UIKit gesture recognizer](https://developer.apple.com/documentation/uikit/uigesturerecognizer) that never recognizes a gesture and cannot prevent the app's recognizers. It does not cancel or delay touches. It watches the active app window; it cannot observe other apps or system keyboard contents. UIKit controls are registered at startup and as their view ancestors receive touches. SwiftUI gestures are visible as physical input, but virtual SwiftUI, keyboard and VoiceOver actions are not all exposed as UIKit controls.

For exact semantic actions, add a breadcrumb in the action handler:

```swift
reporter.recordInteraction("open_settings", fields: ["source": "keyboard"])
```

Add stable `.accessibilityIdentifier("settings-button")` values to views wherever possible. Automatic interaction events record identifiers and view classes, not entered text or accessibility labels. App-supplied semantic fields go through the app's logger as provided.

`accessibility.json` is a bounded traversal of UIKit subviews and [public accessibility containers](https://developer.apple.com/documentation/uikit/uiaccessibilitycontainer), with parent IDs, classes, frames, identifiers, labels, hints and traits. It marks truncation after 500 nodes or depth 30. It omits accessibility values and skips text-field/text-view subtrees. Other visible labels and hints can contain app content, just as the screenshot can. This is not the private VoiceOver/XCTest AX tree; some virtual SwiftUI elements may be absent. The file describes its scope and redaction explicitly.

For a custom UIKit flow, `AccessibilitySnapshot.capture(view)` exposes the same JSON snapshot. The lower-level writer accepts `BugDiagnosticsSnapshot` to attach pre-captured data.

### Reset What's new before UI tests

Create and retain `WhatsNewSeen(launchHookPrefix: "GRABBER", logger: logger)` in app initialization, before the home view first calls `showsRow`. Pass that same store to `WhatsNewRow`. CG tests can then launch with `GRABBER_WHATS_NEW_RESET=1` in `XCUIApplication.launchEnvironment` (or `SIMCTL_CHILD_GRABBER_WHATS_NEW_RESET=1` with simctl). Other apps substitute their prefix. Only the exact value `1` enables the hook.

The initializer synchronously clears `bugkit.whats_new_seen` and logs `bug_hook` with `whats_new_reset: true`. Custom defaults suites and keys are respected. Construct the store once per launch; recreating it during view rendering would reset a dismissal made during that launch. `reporter.runLaunchHooks()` handles report/shake hooks; it does not reset this store. Remove CG's manual plist deletion workaround after adopting this initializer.

### Let people remove screenshot attachments

Apps using `BugReportSheet` get the screenshot ✕ automatically after updating BugKit; no option is required. EA can remove its screenshot-drop workaround if present. CG must first adopt the shared sheet to receive this UI. Custom sheets call `reporter.dropScreenshot()`. Context and diagnostics remain attached. `.keepMoment` keeps the removal for subsequent notes; `.recapture` takes a new screenshot. The writer logs `screenshot_dropped: true` when explicitly removed; an ordinary capture failure does not set it.

### Delay automatic launch reports until the target screen is ready

`<PREFIX>_BUG_AFTER=<seconds>` controls when `<PREFIX>_BUG` captures and saves its reports. The default remains 2 seconds. Values must be between 0 and 86400 seconds (one day); invalid, negative, non-finite and larger values fall back to 2. Zero is allowed. Setting the delay alone does not create a report, and it does not change `_SHAKE_AFTER`, which accepts the same range and is ignored outside it. The `bug_hook` event includes `bug_after`.

For EA's cold-launch `bug_again` smoke check, set `SIMCTL_CHILD_SWING_BUG_AFTER=10` alongside `SIMCTL_CHILD_SWING_BUG="first of two|second of two"` when calling `simctl launch`. Tune the delay to that app's cold startup and assert that the clip/load event precedes each report. For XCUITest, set `SWING_BUG_AFTER` in `launchEnvironment`. This is a fixed delay, not a readiness signal, so a slow launch can still exceed it. Other apps substitute their own prefix.

## Voice input providers

Enable `options.dictation = true` for the microphone button and microphone menu. Apple Speech remains the default. Choose “Refresh microphones” to load the available ports and request mic permission if needed, then choose a mic before starting. The choice is retained in `bugkit.dictation_microphone`; before a fresh list is loaded, it is shown as “Saved microphone”. “Automatic” clears the preference and lets iOS route input. Opening a report never prompts for mic permission, queries inputs, or reconfigures audio.

Explicit Refresh temporarily activates a mixing audio session to discover inputs, then restores the app's category, mode, category options and preferred input. Before restoring a non-mixing category or options that duck or interrupt other audio, it releases the temporary session with `.notifyOthersOnDeactivation`; a busy deactivation error does not discard the listed inputs. Plain ambient or `.mixWithOthers` hosts keep their session active. Refresh can change audio routes or stop host playback, so apps should also return `true` from `microphoneBusy` during playback that must not be interrupted. After actual dictation capture, ambient sessions are deactivated as before.

Hosts with active recording should return `true` from `microphoneBusy`. BugKit checks it again after permission and provider startup, before touching the audio session, and skips discovery or capture if the host has become busy. Direct `NoteDictation` users can supply the same live check through its `hostMicrophoneBusy` initializer argument.

The input is a preference: iOS decides the actual route, and headset selection may also change playback routing. A selected mic that disappears is cleared from the picker on refresh. A route change or interruption during capture stops dictation and preserves the note; select the replacement and start again. Switching inputs during a dictation is intentionally disabled. Actual USB/Bluetooth hardware routing needs verification on a device.

For Deepgram, keep the vendor key in the app's key store, or have your server issue a short-lived access token:

```swift
var options = BugReporterOptions()
options.dictation = true
let hooks = BugReporterHooks(
  logger: log.logger,
  dictationProvider: {
    DeepgramDictationProvider(credential: {
      .accessToken(try await speechServer.fetchDeepgramToken())
      // Or: .apiKey(try await keyStore.deepgramKey())
    })
  })
let reporter = BugReporter(hooks: hooks, options: options)
```

`fetchDeepgramToken` and `keyStore` are your app's code; BugKit does not provide a token server or store keys. Deepgram receives audio when this provider is selected, so the app's voice-input/privacy text should describe that. No vendor credentials or spoken text are written into dictation event logs. The adapter uses [Deepgram's streaming Listen API](https://developers.deepgram.com/reference/speech-to-text/listen-streaming), with Nova-3 by default, configurable model/language, and [API-key or temporary-token authentication](https://developers.deepgram.com/guides/fundamentals/token-based-authentication). It sends `CloseStream` and drains final results before saving.

To use your own server/library, conform an actor or a Sendable type to `BugDictationProvider`, then return a fresh instance from the same hook. `start()` returns an `AsyncThrowingStream<String, Error>`. Each value is the complete spoken text so far, replacing the previous spoken value. BugKit prefixes the text typed before dictation. Audio chunks passed to `appendAudio` are mono signed little-endian PCM16 at 16 kHz. `finish()` must drain final text and close the stream; `cancel()` must promptly unblock stream and network work. The capture queue is bounded; a service that falls behind reports an error rather than dropping words silently.

“Log it” and “Log it and another” wait for the provider's final words. A finish failure keeps the sheet and current note open. Cancel/dismiss invalidates permission, audio and provider callbacks so they cannot write into a later report. The UI shows startup/finish progress and disables duplicate operations.

Apple dictation treats zero-duration partial timing as unavailable, so a later timing revision does not append that partial again. It uses the duration of submitted PCM audio to recognize a genuinely later stretch, and final corrections replace the current stretch. A cumulative final that starts before the current stretch replaces only the earlier stretches its clock overlaps, even when it revises their words; untouched earlier stretches stay. After a clock reset, or without ranges for earlier stretches, which stretches a final covers is ambiguous, so completed speech is kept and the final revises only the current stretch. `DictationJoin` callers can pass `observedAudioEnd:` (the submitted audio duration when observing a result); without timing evidence it favors a revision over guessing that speech restarted. This avoids text-based deduplication and retains deliberate repeated timed utterances.

`voice-keyboard/ios/Host/AudioCapture.swift` and `DeepgramEngine.swift` were the design reference for input selection and streaming segment finalization. Its private `Engine` interface is different; an existing app-owned engine needs a `BugDictationProvider` adapter. Apps already using the shared BugKit report sheet get the mic menu when they enable dictation. CG/EA can opt into Deepgram by adding the factory hook; Mac apps can use the provider API with their own PCM capture, since the shared report sheet and mic picker are iOS views.

## macOS storage and Command Line Tools

`BugStore()`, `SessionLog(prefix:)` and `CrashReports.shared` share `BugStorage.defaultDirectory`.
On macOS this is `~/Library/Application Support/<bundle ID>/`; an unbundled SwiftPM/command-line app uses
its executable name, such as `lcd-timer`. iOS and watchOS continue using their app-container Documents folder.
Report and log paths remain relative to the root, so the same report format works on every platform.

Existing explicit directories remain authoritative. An app such as Magic Monitor using
`~/Library/Application Support/MagicMonitor` can retain that store; pass the same root to `SessionLog` and
its `crashes` child to `CrashReports.install(folder:logger:)`. Updating does not move or delete existing
reports from `~/Documents`. If an app previously used the old defaults, retain an explicit old root while
draining it, or move its owned evidence deliberately before switching all three writers together.

The What's new views remain available to Mac apps. Their Mac dismissal state uses explicit SwiftUI wrapper
storage to avoid requiring the `@State` macro plugin that Command Line Tools-only SDKs do not ship.
`WhatsNewSeen` remains a Foundation API. CI builds and runs the CLT-only consumer in `Tools/CLTConsumer`.
A desktop-only GUI test presses the Mac row's ✕ and checks the row disappears and stays hidden; headless CI
skips it, so run it on a logged-in Mac with `BUGKIT_GUI_TESTS=1 swift test --filter WhatsNewMacDismissTests`.

## App Group storage

For a host app that shares evidence with an extension, point the store and log at an explicit directory inside the App Group. Enable the same App Group entitlement on the host and whichever extension writes its own evidence. Resolve it through `FileManager`; do not hard-code the container's UUID or silently fall back to the app's private Documents.

```swift
guard let group = FileManager.default.containerURL(
  forSecurityApplicationGroupIdentifier: "group.com.example.voicekeyboard"
) else { fatalError("Missing App Group entitlement") }
let documents = group.appendingPathComponent("Documents", isDirectory: true)
try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
let store = BugStore(documents: documents)
let log = SessionLog(prefix: "host", documents: documents)
CrashReports.shared.install(folder: documents.appendingPathComponent("crashes"), logger: log.logger)
let reporter = BugReporter(
  hooks: BugReporterHooks(sessionLog: { log.position }, logger: log.logger, flushLog: { log.flush() }),
  store: store)
```

Keep report paths relative to this `documents` root. Add `"app_group": "group.com.example.voicekeyboard"` to this app's listener entry; it then pulls the group's `Documents` through `appGroupDataContainer`, including logs and crash evidence. Existing entries without `app_group` still pull the app container. [Listener configuration](ops/listener.md#configure) includes the full entry and backfill commands.

For memory-constrained keyboard extensions, link BugKit into the **host target only**, leave it out of the extension's package dependencies/link phase, and keep the extension's existing minimal evidence writer. The host can read or attach that evidence through its hooks. Do not assume the UIKit reporter is extension-safe: it uses `UIApplication`. Use distinct filenames or process prefixes for host and extension logs; this directory example does not establish cross-process safety for shared log/crash writers. A separate extension-safe product is tracked in [#26](https://github.com/idvorkin/bug-kit/issues/26).

## Private-text apps

An app displaying transcripts or other private text can disable automatic screen images while keeping the issue note and its app-supplied state:

```swift
var options = BugReporterOptions()
options.captureScreenshots = false
options.dictation = false
options.captureAccessibility = false
options.recordInteractions = false
let reporter = BugReporter(hooks: hooks, options: options, store: store)
```

`captureScreenshots` defaults to `true`. Turning it off skips the renderer for the sheet, “Log it and another” recapture, and launch-hook reports. No screenshot is displayed or written by those paths. Automatic reports already have no screenshot. The other three capture features default to `false`; set them explicitly here so this privacy configuration is easy to audit. These options do not redact the user's note, app-provided context, session logs or `extraFiles`: the app must keep dictated text out of those hooks and logs. Apps calling `BugReportWriter.save` directly own their `screenshotPNG` argument.

## Private CloudKit delivery

This path is opt-in and intended for your devices on the same iCloud account. A phone on cellular can upload a
report while away from the Mac; the Mac's login-session listener downloads it on its next poll, files it in the
configured tracker and appends the agent's inbox line. Keep the Mac awake/online and the listener running.
Neither Bluetooth pairing nor `devicectl` reachability is required for CloudKit. `bugs.jsonl` and local evidence
remain available for the existing device pull. No runtime package dependencies are added.

The actual container, team and environment for Igor's devices live only in the Mac's
**`~/.config/bug-kit/cloudkit.json`**. Every agent reads its `container` and `environment` there. This document
and committed project files use the placeholder `iCloud.com.example.BugKitReports` and never real team IDs,
UDIDs, emails or account identifiers.

### Each app's agent

1. **Pin BugKit 0.3.2 exactly for new adoption, the Mac fixes and the dictation fix**. Existing apps on 0.3.0
   can stay there: their CloudKit report format remains compatible with the updated reader. lcd-timer and Magic
   Monitor's Mac side need 0.3.1 or later for the Mac storage, CLT and listener fixes; 0.3.2 also stops dictated
   notes from repeating their words and adds the CloudKit reader's missing query index diagnostics.
   - Xcode: **File › Add Package Dependencies** → `https://github.com/idvorkin/bug-kit` → **Dependency Rule:
     Exact Version** → `0.3.2`. For an existing dependency, use the project's **Package Dependencies** tab.
   - XcodeGen: `packages: { BugKit: { url: https://github.com/idvorkin/bug-kit, exactVersion: 0.3.2 } }`.
   - SwiftPM: `.package(url: "https://github.com/idvorkin/bug-kit", exact: "0.3.2")`.
2. Add **Signing & Capabilities → + Capability → iCloud**, check **CloudKit**, and select the shared container
   from the local config alongside any existing iCloud Documents containers. All sending apps and the Mac reader
   must have this same container authorized in their provisioning profiles. Do not reuse a Documents container
   without enabling CloudKit for it. Keep team/account/device identifiers in local configuration, not committed
   project files or docs.
3. Sign in to the same **iCloud user account** on the phone/watch and Mac. The developer signing account is a
   different requirement. Sender and reader must use the same **Development or Production** database
   environment: Xcode-installed debug builds use Development; TestFlight and App Store builds use Production,
   so deploy the schema before using them.
4. Retain **one delivery actor per store** for the app's lifetime and pass it to the reporter (or directly to
   `BugReportWriter`). Use the exact same store, including its App Group Documents path when applicable:

```swift
let delivery = CloudKitReportDelivery(
  containerIdentifier: "iCloud.com.example.BugKitReports", store: store, logger: log.logger)
let reporter = BugReporter(
  hooks: BugReporterHooks(sessionLog: { log.position }, logger: log.logger, flushLog: { log.flush() }),
  options: options, store: store, info: info, delivery: delivery)
Task { await delivery.start() } // launch; repeat on foreground
```

For a watch or Foundation-only caller:

```swift
let writer = BugReportWriter(store: store, info: info, logger: log.logger, delivery: delivery)
let report = await writer.save(note: note, screen: "watch", context: [:], screenshotPNG: nil,
                               log: log.position, extraFiles: nil)
```

CI compiles both snippets against the iOS and watchOS SDKs from `Tests/Adoption/CloudKitAdoption.swift`; keep
them identical when editing either.

The relevant entitlements are `com.apple.developer.icloud-services = ["CloudKit"]` and
`com.apple.developer.icloud-container-identifiers = ["iCloud.com.example.BugKitReports"]`; Xcode/provisioning
also supplies the container environment for iOS/watchOS apps. Enable the iCloud capability and select the
authorized container; do not manually add the Mac distribution reader's environment entitlement to their
entitlements files. Do not copy a signature's generated team-prefixed entitlements into source control.
The app owns the opt-in preference: construct/pass delivery only when enabled. `stop()` stops
app-level retry timers; an already submitted CloudKit daemon operation may still finish.

**Only reports saved after opt-in are delivered.** The first `start()` or `enqueue` records the IDs already in
`bugs.jsonl` as pre-opt-in history; those stay local for the device pull and are never uploaded. Every later
report is eligible by ID, not by its timestamp: if the app dies between saving and enqueueing, or evidence
cannot be staged yet, the next `start()` or save stages it again. Call `start()` at launch so the boundary is
recorded before the user can save. The boundary is recorded once per store and container: if the app later
turns delivery off and back on, reports saved while it was off are uploaded too.

Saving completes locally before a network request. The immutable outbox lives below
the store root at `bug-delivery/cloudkit-<container-hash>/`. Uploads explicitly allow cellular, use user-initiated QoS,
and are long-lived CloudKit operations so the system can continue an already submitted operation after the app
exits. Only an idle request times out after 60 seconds; a large upload over a slow cellular link is not cut off
by a total deadline. Its operation ID is persisted and callbacks reattach after restart. Stable report UUID
record IDs make uncertain acknowledgements safe to retry. Transient network and account errors, including a
signed-out iCloud account, retry automatically with exponential backoff (5 seconds up to five minutes),
respecting CloudKit's retry-after delay. Call `start()` at launch/foreground to resume work after termination;
`flush()` runs one pass and returns the uploaded count. Timers cannot run while iOS suspends an app, and new
retries still need a later app execution opportunity. A failed save that never submitted an operation is not
guaranteed to reach the Mac while the app remains suspended. Test that case on the device; do not infer it from
a local success message.

Missing/oversized evidence stays local and logs `bug_delivery_pending`, without keeping retries alive; the
next `start()` or save tries again. A corrupt queued payload or permanent configuration error logs
`bug_delivery_stopped` and needs attention. Limits: 100 attachments, 20 MB total unencoded evidence, 30 MB
encoded asset. Large video reports use the local/device fallback; trim evidence before saving if cloud delivery
is required. Account bindings prevent silently delivering an old outbox into a different iCloud account.
Do not erase them casually; finish the original account's queue or explicitly archive its store first.

### Mac reader and listener

A bare command-line tool cannot carry the profile required for CloudKit's restricted entitlement. The only
reader is a tiny headless `BugKitCloudReader.app`, built from `Tools/CloudKitReader` by XcodeGen/Xcode, with
`Contents/embedded.provisionprofile`. Its executable can be invoked directly by the listener; it checks its
bundle, signature, embedded profile, container entitlement and configured environment before touching CloudKit.
The supplied build recipe signs with **Apple Development** and omits
`com.apple.developer.icloud-container-environment`: Mac Team Development profiles do not grant that key.
Preflight accepts its absence only when the configured environment is Development; explicit environment
mismatches are rejected. Production requires a separately provisioned distribution reader with an explicit
Production entitlement (for example, Developer ID signing). The Development build script rejects a
Production configuration instead of installing a reader that cannot pass this check.
Apple documents this
[app wrapper requirement](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

The signed reader builder takes the signing lock and runs the [screen-lock guard](ops/signing.md#no-provisioning-builds-while-the-mac-is-locked). It waits for Mac unlock before provisioning, prevents display sleep during the build, and stops on account-loss messages without installing or retrying.

Keep signing/runtime values in **`~/.config/bug-kit/cloudkit.json`** (mode 600), never in this repo:

```json
{
  "team": "YOURTEAMID",
  "bundle": "com.example.BugKitCloudReader",
  "container": "iCloud.com.example.BugKitReports",
  "environment": "Development",
  "app": "~/Applications/BugKitCloudReader.app",
  "inbox": "~/tmp/agent/bugs/cloudkit"
}
```

**The generated Xcode project shows `com.example` placeholders unless locally overridden.** The build script
passes the real values from this JSON through ignored `DerivedData/CloudKitReader/signing.xcconfig` to its
command-line build; opening the generated project in Xcode does not apply that override. Before using
**Signing & Capabilities** in the GUI, set the generated project's bundle ID and container to the actual
`bundle` and `container` from the local config. Do not register the example app IDs or containers, or use
**Fix Issue** while placeholders are selected. Keep these GUI overrides local; regeneration replaces them.

Building is heavy work: only one build or simulator runs on this Mac at a time. Wait for an explicit build turn,
then run a standalone build under the shared build lock:

```sh
chmod 600 ~/.config/bug-kit/cloudkit.json
lockf -k -t 3600 ~/tmp/agent/locks/build.lock python3 scripts/build-cloudkit-reader.py
# Compile without provisioning when setting up CI/development (cannot access CloudKit):
lockf -k -t 3600 ~/tmp/agent/locks/build.lock python3 scripts/build-cloudkit-reader.py --unsigned
```

Do not take `build.lock` again inside a command whose caller already holds it and says so;
the nested `lockf` would wait for itself. The signed build additionally takes
`lockf -k -t 900 ~/tmp/agent/locks/xcode-signing.lock xcodebuild ... -allowProvisioningUpdates`, uses two compiler
workers, verifies the signature/profile and installs to the local config's `app` path. Generated signing
settings and raw logs are ignored under `DerivedData/`; they can contain private identifiers. Do not commit
or publish those logs.

Run signing builds outside the agent sandbox so Xcode can access its existing account session; the build
uses both `-allowProvisioningUpdates` and `-allowProvisioningDeviceRegistration` under the signing lock.
`No Accounts` from a sandboxed process does not establish that Igor must add an Xcode account.

Add to **`~/.config/bug-kit/apps.json`**, retaining its existing app/tracker entries:

```json
{
  "poll_seconds": 60,
  "cloudkit_config": "~/.config/bug-kit/cloudkit.json",
  "apps": [
    { "name": "example", "bundle": "com.example.app", "tracker": { "kind": "github", "repo": "owner/app" } }
  ]
}
```

The listener invokes the helper **first on every poll**, even with no paired devices or if device discovery
fails, then pulls reachable devices as before. It still consumes complete previously downloaded folders after
a failed sync, but the failure makes status unhealthy. Dry runs skip CloudKit downloads and consume only
existing local folders.

Reports use private `BugKitReport` records keyed by UUID, with `bundle` (String), `reportedAt` (Date), `payload`
(Asset). The reader paginates, skips complete local folders, and atomically installs report/evidence/length
manifests. Cloud records are retained. Download folders and local receipt files are retained too; do not delete
them as routine cleanup or old reports will download again. The same seen-store delivery ledger deduplicates
CloudKit and device pulls by app bundle + report UUID; existing inbox history also recovers receipts after a
lost seen-store write. An inbox-write failure retries that handoff without creating another tracker issue.
CloudKit downloads file immediately, because the sender uploads only post-opt-in reports; the device lane
keeps its existing first-contact baseline.

Before the first Development upload creates `BugKitReport`, CloudKit can answer the initial record-type
query with `unknownItem` (code 11). The reader treats that initial query as an empty successful sync:
`cloudkit_sync` has `ok: true` and `downloaded: 0`, and later polls still query for newly uploaded reports.
Missing assets, pagination failures, authorization/network failures and missing query indexes still fail
the sync. An empty success is bootstrap health, not evidence that a saved report reached the Mac.

After the first upload, code 12 (`invalidArguments`) with **“Field 'recordName' is not marked queryable”**
means the Development schema is missing the index required to list records. This is a failed sync, not an
empty inbox. Add **Development → Schema → Indexes → BugKitReport → Add Basic Index → recordName → Queryable
→ Save** in the [CloudKit Console](https://icloud.developer.apple.com/), wait for the index to be ready, and
retry. No Sortable index is needed: the reader does not sort the query. The reader cannot create this index.
The listener's `cloudkit_sync` log and health expose `code: 12`, `reason: missing_query_index`, and a fixed
index action without copying raw server/account details.

For a local investigation, add **`--diagnostics`** after the reader arguments to print the full CKError,
server message and user info to stderr. Normal operation keeps raw errors out of logs. Diagnostic output can
contain private identifiers; keep it local when reporting a problem:

```sh
~/Applications/BugKitCloudReader.app/Contents/MacOS/BugKitCloudReader \
  --container iCloud.com.example.BugKitReports --inbox ~/tmp/agent/bugs/cloudkit \
  --environment Development --diagnostics
```

Substitute the container from your local config. Run the signed app outside an agent filesystem sandbox;
sandboxed execution can hide Xcode accounts or iCloud access. Retrying after an index fix should return
`ok: true` and download eligible records; confirm each report reaches filing and the agent inbox separately.


### Igor's setup and real acceptance check

Before the live check, confirm these setup steps with Igor:

1. **Xcode → Settings… → Accounts**, confirm the existing developer account and team are available. Add or
   refresh the account only if needed; run the signing build outside the sandbox first. Then, in each
   adopting app's target and in the generated `BugKitCloudReader` project, open
   **Signing & Capabilities**, select that team, and under **iCloud** check **CloudKit** and the container named
   in `~/.config/bug-kit/cloudkit.json` (use **+** under Containers to create it once if it does not exist).
2. In the [developer portal](https://developer.apple.com/account/resources/identifiers/list): **Certificates,
   Identifiers & Profiles → Identifiers →** each app ID and the reader's bundle ID **→ iCloud → Edit**, assign
   the same container, **Save**. Regenerate or let Xcode refresh the profiles.
3. Install a build of each app that saves one report in Development, so the `BugKitReport` record type exists.
   In [CloudKit Console](https://icloud.developer.apple.com/) select the container → **Schema → Indexes →
   BugKitReport → Add Basic Index → `recordName`, Queryable → Save**. Before using TestFlight/App Store builds,
   **Deploy Schema Changes…** to Production and use a distribution-signed Mac reader with an explicit
   Production environment entitlement before setting `"environment": "Production"` in the local config.
   The supplied Apple Development build recipe handles Development only.
4. Sign the phone/watch and Mac into the same iCloud user account, and allow
   cellular data for each app under **Settings → Cellular**.
5. Run the signed reader build above, then `listener/bug-listener doctor --json`; `cloudkit_signing` must be ok.

Then the physical acceptance check. Use a synthetic report UUID to follow each hop: app `bug_report` →
`bug_delivery_queued` → `bug_delivery_uploading` / `bug_delivery_retry` → `bug_delivery_uploaded` → Mac
`cloudkit_downloaded` → `file` → `inbox`. Query the Mac's `listener.log` and `inbox.jsonl` for that UUID and
require exactly one issue and one inbox line. A phone-local report or CloudKit upload acknowledgement alone is
**not** the delivery test. Disable Wi-Fi, make the phone unreachable to `devicectl`, save over cellular and
require the Mac inbox line within one poll after upload. Repeat after offline save/reconnection and app restart;
verify pending retries rather than silent loss, then return home and pull the device to prove deduplication.
Confirm a report saved before opt-in never uploads. `doctor --json` checks signing without querying iCloud;
`status --json` reports the last sync result. Missing entitlements, wrong environment/index, expired profiles,
disabled cellular/iCloud or a sleeping/offline Mac must be treated as failed delivery, not hidden by an old
download folder. This live device/cellular test has not been run; it requires Igor.

### watchOS and #25

The package declares watchOS 10 support. The model, local store, writer, logger and CloudKit sender compile
with the watchOS SDK, allowing think-a-card's watch target to submit directly to the private container without
waiting for its paired iPhone. Give that watch target its own authorized App ID/profile and the same shared
container, and call `start()` when the watch app launches or becomes active. This does not add a watch report
dialog, shake handling, dictation UI, screenshots, or a WatchConnectivity relay, so #25 remains open for those
integration choices and real watch/cellular validation.

# Reporting a problem

Part of the [BugKit stories](README.md).

---

### User Story 001:

- **Summary:** Report a problem in five seconds with the evidence attached
- **From:** EA story 022; CG story 142; MM story 040
- **Status:** `BugReporter`, `BugReportSheet` and `BugReportWriter`.
  - The writer is verified on the host by `writerSavesTheScreenshotTheExtraFilesTheLineAndTellsTheLogger`.
  - The sheet is verified by typecheck.
  - The dialog on a device waits for the first app to migrate.

#### Use Case:
- **As someone** who just saw the app do something wrong
- **I want to** shake the device, type one line and move on
- **so that** the developer gets the screen, the build and the session log without my explaining

#### Acceptance Criteria:
- **Scenario:** A shake
- **Given:** the app is open on any screen
- **When:** I shake the device, type "counted 1 rep, there were 13" and tap *Log it*
- **Then:**
  - the report is stored as one line in `Documents/bugs.jsonl`, with my note, a picture of the screen as it was at the shake, the screen's name, the build and commit, and the session log's path with the moment in it;
  - the session log has `bug_report_open` and `bug_report`;
  - the app can show "Problem logged. Thanks."

- **Scenario:** Changing my mind
- **Given:** the dialog is open with a note typed
- **When:** I tap *Cancel*, press Escape, or swipe the sheet down
- **Then:** nothing is saved, the log has `bug_report_cancel`, and nothing else in the app changed

---

### User Story 002:

- **Summary:** The report opens over whatever is on screen, sheets included
- **From:** EA #41; CG #182 (story 142, "A shake over a dialog")
- **Status:**
  - `BugReporter.open` captures a window, then presents from `BugReporter.topmost`: a shake uses the shaken
    window, a "report another" reopen uses the window of the dialog it just dismissed, and anything else uses
    the key window. Verified by typecheck.
  - CG's `ShakeOverSheetUITests` covers the same design in CG.
  - iOS's shake is heard at `UIWindow`, so it reaches BugKit whatever holds first responder (#62). The
    simulator's `ShakeTests` cover a sheet, a focused text field in a sheet and an alert
    (`shakeOverASheetOpensTheReportOverThatSheet`, `shakeInAFocusedTextFieldInsideASheetOpensTheReport`,
    `shakeOverAnAlertOpensTheReport`), the report opens over the shaken window rather than the key one
    (`theReportOpensOverTheWindowThatWasShakenNotTheKeyOne`), and a shake in another scene's window leaves this
    scene alone (`aShakeInAnotherScenesWindowLeavesThisSceneAlone`); a physical shake on a device is still to do.

#### Use Case:
- **As someone** reporting a problem with a settings sheet or a list open
- **I want to** have the report open on top of it and the sheet still there afterwards
- **so that** reporting never loses my place, and the picture shows what I was looking at

#### Acceptance Criteria:
- **Scenario:** A shake over a sheet
- **Given:** a sheet is up (settings, a list, a naming card)
- **When:** I shake, then cancel; and shake again
- **Then:**
  - the report opens over the sheet each time, and its picture shows the sheet;
  - after *Cancel* or *Log it* the sheet is still there;
  - `bug_report_open` says what it opened `over`.

- **Scenario:** A second shake while typing
- **Given:** the dialog is open with half a note typed
- **When:** the device is shaken again
- **Then:** the note is kept, and the log says `already_open` (`aSecondShakeWhileTypingKeepsTheNote`, host)

- **Scenario:** The dialog went away without a cancel (BugKit #96, CG #425)
- **Given:** a report was open and the phone locked, so the dialog is gone but was never cancelled or saved
- **When:** I shake or press Report a problem
- **Then:** a fresh report opens, and the log says `bug_report_cancel` with `stale: true` first (`aReportWhoseDialogIsGoneDoesNotBlockTheNext`, host; `aReportSheetDismissedBehindBugKitsBackDoesNotBlockTheNext`, simulator; the lock itself to verify on the phone)

---

### User Story 003:

- **Summary:** Several problems in a row: "Log it and another"
- **From:** EA #212 (story 022); MM story 061 (mmn-2jn); CG story 142, a85e228
- **Status:**
  - `BugReportFlow.log(another:style:)`, verified on the host by `logItAndAnotherSavesThenOpensAFreshReport` and `recaptureClosesThenReopensAFreshReport`.
  - Unique folders within one second are verified by `folderNamesAreUniqueWithinOneSecond`.
  - Two saves at once are verified by `sixtyFourConcurrentAppendsGiveSixtyFourValidLines`.

#### Use Case:
- **As someone** who noticed several things wrong at once
- **I want to** save a report and be straight back in an empty one
- **so that** I file each bug on its own, without shaking again for each

#### Acceptance Criteria:
- **Scenario:** Keep the moment (`another: .keepMoment`, the default)
- **Given:** a report has a note typed
- **When:** I tap *Log it and another*, type a second note and tap *Log it*
- **Then:**
  - two reports are stored, each with its own note, both with the shake's picture;
  - the dialog stayed up between them, and its note field was empty and focused.

- **Scenario:** A fresh picture each time (`another: .recapture`)
- **Given:** the app chose `.recapture`
- **When:** I tap *Log it and another*
- **Then:**
  - the dialog closes;
  - once it is off screen, the screen underneath is captured again;
  - a fresh, empty dialog opens with `source` "another".

- **Scenario:** Two in one second
- **Given:** two reports are saved within the same second
- **Then:**
  - they get folders `<stamp>` and `<stamp>-2`;
  - `bugs.jsonl` has both lines, neither overwriting the other (MM mmn-cfr).

---

### User Story 004:

- **Summary:** A gentle shake opens the report, not only a hard one
- **From:** CG story 146 (#164)
- **Status:**
  - `ShakeGesture` (host: `aQuickLightShakeIsAShake`, `onePushIsNotAShake`, `aSlowSwayAndAWeakJiggleAreNotShakes`, `oneShakeOpensOneSheet`).
  - `ShakeMotion`, behind `options.gentleShake` (on by default), verified by typecheck.
  - The threshold on a device was not checked in BugKit. CG has not checked it on a phone either.

#### Use Case:
- **As** the person reporting problems many times a day
- **I want to** open the report with a quick, gentle shake
- **so that** reporting stays a reflex, not a workout

#### Acceptance Criteria:
- **Scenario:** A quick back-and-forth
- **Given:** the app is open and in front
- **When:** I give the device three quick, light flicks (about 1.8 g) that iOS's own shake ignores
- **Then:**
  - the report opens once;
  - the log has `shake` with source motion and `peak_g`;
  - walking with the device, or setting it down on a bench, opens nothing.

---

### User Story 005:

- **Summary:** A button, and ⌘I on a keyboard, for when shaking is awkward
- **From:** MM story 040 (⌘I), MM story 09 (iPad: Settings → Report a bug); EA's "Report a problem" on the start panel; CG Diagnostics
- **Status:**
  - `BugReportButton` and `options.commandI`, verified by typecheck.
  - `shakeEnabled = false` silences shakes during instrumented runs (EA story 037).

#### Use Case:
- **As someone** with the iPad on a stand, or typing on a keyboard
- **I want to** open the report with a button or ⌘I
- **so that** I can report without picking the device up

#### Acceptance Criteria:
- **Scenario:** ⌘I on the iPad
- **Given:** a hardware keyboard is attached
- **When:** I press ⌘I
- **Then:** the report opens as a shake would, and `bug_report_open` has source `key`

---

### User Story 006:

- **Summary:** Keys inside the dialog
- **From:** MM story 040 ("press Return"), story 061 (⌘Return for Save and Another)
- **Status:** `options.dialogKeys`, verified by typecheck.
  - In BugKit, ⌘Return is *Log it* and ⇧⌘Return is *Log it and another*.
  - This differs from MM, where Return saves and ⌘Return saves another. BugKit's note field is multi-line, so Return types a new line.

#### Use Case:
- **As someone** reporting from a keyboard
- **I want to** save, save-and-another and cancel without the mouse or a tap
- **so that** reporting does not interrupt my hands

#### Acceptance Criteria:
- **Scenario:** Keyboard only
- **Given:** the dialog is open with a note
- **When:** I press ⌘Return / ⇧⌘Return / Escape
- **Then:** the report is logged / logged with a fresh one opened / cancelled

---

### User Story 007:

- **Summary:** Speak the note
- **From:** CG #239 (story 142, "Speaking the note")
- **Issues:** #7, #1 (voice-input clarification); beads bug-9j5, bug-ig8
- **Status:**
  - `NoteDictation`, behind `options.dictation` (off by default: it needs the speech and microphone usage strings). Verified by typecheck.
  - `DictationText.merge` is verified on the host by `dictatedWordsGoAfterTheTypedNote`.
  - The permission prompts and music carrying on are device checks, still to do.
  - The error is a `BugProblemView` with Copy error, behind `options.copyableErrors` (on), from CG's ProblemView
    (bug-kit#7). The copied text is verified on the host by `BugProblemTests`; the view by typecheck. Pasting from a
    real refusal is a device check, still to do.

#### Use Case:
- **As someone** with one hand on a kettlebell or a steering wheel
- **I want to** tap the microphone and say what went wrong
- **so that** a report takes no typing

#### Acceptance Criteria:
- **Scenario:** Speaking
- **Given:** the dialog is open, with or without words typed, and no call is up
- **When:** I tap the microphone, say "the timer skipped the rest", and tap it again
- **Then:**
  - the words appear after anything I had typed;
  - music that was playing keeps playing;
  - the log has `dictation_start` and `dictation_stop`.

- **Scenario:** The microphone is busy or refused
- **Given:** a call holds the microphone (`microphoneBusy`), or speech recognition is off
- **Then:**
  - the button is off, or the dialog says why in words;
  - the log has `dictation_error` with the reason.

- **Scenario:** Copying the error
- **Given:** the dialog says why dictation failed
- **When:** I tap Copy error and paste into an issue
- **Then:**
  - the paste has the message, `context: BugReportSheet.dictation`, `build:` with the version and commit, and the
    state (`auth`, `mic`, `recognizer` or `error`, and `mic_busy`), one per line;
  - the log has `ui` with `action: copy_error` and `from: tap`.

---

### User Story 008:

- **Summary:** The dialog says where the report goes
- **From:** MM story 062 ("Nothing leaves this iPad"), story 040 ("nothing leaves the Mac")
- **Status:** `options.privacyNote`, shown under "Attached automatically". Verified by typecheck.

#### Use Case:
- **As someone** whose screen may show health data, places or a journal
- **I want to** see that the report stays on the device until the developer pulls it
- **so that** I report freely

#### Acceptance Criteria:
- **Scenario:** The note
- **Given:** the app set `privacyNote: "Nothing leaves this iPad."`
- **When:** the dialog opens
- **Then:** the line shows under what is attached

---

### User Story 009:

- **Summary:** A simulator can make reports without a hand (technical)
- **From:** EA `SWING_BUG` (story 026), CG `GRABBER_BUG` and `GRABBER_SHAKE_AFTER` (story 142)
- **Status:**
  - `BugLaunchHooks` is verified on the host by `launchHooksParseNotesAndShakeAfter`.
  - `BugReporter.runLaunchHooks` is verified by typecheck.
  - `scripts/smoke-lib.sh`, the shared plumbing for an app's smoke script (EA, CG and MM's rules), is verified on the
    host by `scripts/tests/test_smoke_lib.py` with a stub simctl. A real app's smoke script on it is still to come.

#### Use Case:
- **As an** agent verifying a change on the simulator
- **I want to** have the app save a report, or open the dialog, from an environment variable
- **so that** the check asserts on the log and the files instead of tapping

#### Acceptance Criteria:
- **Scenario:** Two reports from the hook
- **Given:** `launchHookPrefix: "APP"`
- **When:** the app launches with `SIMCTL_CHILD_APP_BUG="first|second"`
- **Then:**
  - two reports are saved about two seconds after launch, each with the screenshot;
  - the log has `bug_hook` and two `bug_report` lines.

- **Scenario:** A smoke check that cannot pass by accident
- **Given:** a smoke script on `scripts/smoke-lib.sh`
- **When:** the app crashes before it logs, the launch writes no new log, a step logs `error`, or the scripted flow
  stops before `selftest_finished`
- **Then:** the run fails and names why. An older launch's log never satisfies the check.

### Remove a screenshot before saving

**Issues:** #14

The screenshot thumbnail has an accessible “Remove screenshot” button. Removing it keeps the note and context but saves no screenshot path or `screen.png`, and the `bug_report` event includes `screenshot_dropped: true`. “Log it and another” retains this choice for `.keepMoment`; `.recapture` and a new presentation capture fresh evidence. Host coverage: `screenshotDropPersistsForSameMomentAndResetsOnRecapture`, `droppedScreenshotIsAbsentFromSavedReportAndFolder`.

### Delay automatic launch reports for cold startup

**Issues:** #19

Given `<PREFIX>_BUG` notes and `<PREFIX>_BUG_AFTER=10`, reports capture evidence after ten seconds instead of the default two. Invalid, negative, non-finite and over-one-day values retain the default; zero is accepted. A delay without notes does not save reports. Host coverage: `automaticReportDelayDefaultsToTwoSeconds`, `automaticReportDelayAcceptsOnlyFiniteNonnegativeValues`, `shakeDelayAcceptsOnlyBoundedNonnegativeValues`. EA's cold-launch smoke check can set `SWING_BUG_AFTER` and verify that the clip's load event precedes the report.

### Choose the microphone and transcription service

**Issues:** #1, #48; beads bug-9j5, bug-ig8

With dictation enabled, the report offers Automatic and an explicit “Refresh microphones” action to load iOS inputs. Opening a report does not reconfigure audio. The saved input preference applies to a fresh dictation and shows as “Saved microphone” until refreshed. Missing inputs are cleared on refresh; changes during capture stop dictation without erasing text. Apple Speech is the default, while a host factory can choose Deepgram or another streaming provider. Cloud providers skip Apple Speech authorization. Typed words and finalized speech survive interim revisions; save waits for final words, and canceled permission/network callbacks cannot alter another report.

Host coverage (Foundation, `swift test`): `DictationProviderTests.swift` verifies transport, Deepgram handshake credentials, segment revisions, final flushing and cancellation. iOS simulator coverage (`Tests/iOS` bundle): `NoteDictationTests.swift` uses fake iOS capture/permissions to verify selected input, a saved microphone shown before any explicit refresh, no microphone discovery or capture while the host records (including when it starts recording during permission or provider startup), Apple's quiet end after Stop, final text before save, no saved report when dictation on an empty note fails or hears nothing, permission cancellation, service failure, disappeared-input fallback, and that discovery stays active only for plain ambient/`.mixWithOthers` hosts. Physical mic routes and live vendor transcription need separate device/service verification.

### See the input level, and choose the microphone, on every voice input

**From:** Igor, 2026-10-26: "When we're doing voice input can we make sure to be able to have a mic selector and
then see the audio input levels? This should probably be on every voice input."
**Issues:** beads bug-0b9
**Status:** in progress on branch `mic-level-meter`. The level arithmetic (silence, full scale, smoothing, the
update rate) is verified on the host by `DictationLevelTests`; the published level rising and returning to empty by
the iOS simulator bundle (`NoteDictationTests`); the controls by typecheck. A real voice moving the meter is a
device check, still to do.

- **As someone** speaking a note or a message into any of the apps
- **I want to** see a level that moves with my voice, and choose the microphone right beside the mic button
- **so that** I know at once whether I am heard, and by which microphone, before I say a whole sentence to nothing

- **Scenario:** The level moves with my voice
- **Given:** dictation is on and I tap the microphone
- **When:** I speak, then stop
- **Then:**
  - the meter rises as I speak and falls back smoothly when I stop, without flicker;
  - it redraws about fifteen to twenty times a second, not once per audio buffer;
  - silence reads as empty and a full-scale signal as full.

- **Scenario:** Not listening
- **Given:** voice input is stopped, finishing, cancelled or failed
- **Then:** the meter is empty.

- **Scenario:** The same controls in every app
- **Given:** an app with its own voice input button built on BugKit's dictation
- **When:** it puts BugKit's voice input controls beside its button
- **Then:** it shows the same level meter and the same microphone picker as the report dialog (Automatic, the inputs
  iOS offers, Refresh microphones), with the same rules: a pick applies to the next dictation, and the picker is off
  while listening or while the app holds the microphone.

- **Scenario:** The report dialog
- **Given:** `options.dictation` is on
- **When:** the report dialog opens
- **Then:** the microphone picker and the level meter sit under the note.

### Report private-text apps without automatic screen images

With `captureScreenshots = false`, opening a report and launch-hook saving skip the renderer. The issue note and app-provided state still save; automatic screen images are neither displayed nor written. The default remains capture enabled. `ScreenshotPrivacyTests` verifies the lazy capture gate and persisted metadata on the host; its iOS-only case drives the real sheet and launch hook. Dictation, accessibility and interaction recording remain separately configurable.

### Pull evidence from an App Group

An app can give its store, log and crash capture the App Group's `Documents` directory. A listener entry with `app_group` reads that group's report index, report folders, logs and crashes using `appGroupDataContainer`. An entry without it retains `appDataContainer`. `scripts/pull-reports.sh` and its `--check` use the same domain for every copy, including `pull_extra`. Fake-tool listener and pull-reports tests verify the actual command arguments, identifier validation and that `--check` lists the group's unfiled reports. Paired-device entitlement/access checks remain a separate device verification.

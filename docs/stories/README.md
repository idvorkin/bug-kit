# BugKit user stories

These stories are BugKit's spec. Each one merges the stories that Exercise Analyzer (EA), Context Grabber's native app (CG) and Magic Monitor (MM) wrote for reporting problems, logs and What's new. "From" names the app story or issue it came from.

Each story uses the apps' format:
- **Summary**: one line.
- **From**: the source story or issue.
- **Status**: what in BugKit implements the story, and which test verifies it, by rung.
- **Issues** (when there are any): the issues filed against the story, e.g. `#6, #7`. A bug gets its entry before
  the fix. What's new maps an issue to its story through this line.
- **Use Case**: who wants it, what they want, and why.
- **Acceptance Criteria**: Given / When / Then scenarios.

There is no story without a test or a named rung. Where the only check is a device, the Status line says so.

The Status line is a running log, not a checkbox (CG `docs/stories/README.md`):
- Each change adds a bullet with what changed, its commit or PR, and the rung it was verified on.
- It names what is not checked yet, such as "a device check, still to do" or "verified by build only: the first real crash will verify it".
- A later session then reads what is left to verify, without checking everything again.

The rungs are described in [../ops/test-ladder.md](../ops/test-ladder.md):
- **host** means `swift test` or the listener's pytest;
- **typecheck** means the iOS UI compiled against the iOS SDK;
- **device** is an app on a real phone or iPad.

| File | Stories |
|---|---|
| [01-reporting.md](01-reporting.md) | 001–009: the shake, the dialog, "Log it and another", dictation, the keyboard |
| [02-evidence.md](02-evidence.md) | 010–018: the report on disk, session logs, retention, extra files, crashes, UI diagnostics and automatic reports |
| [03-off-the-device.md](03-off-the-device.md) | 020–027: pulling, filing once, the listener, never uploading pictures |
| [04-whats-new.md](04-whats-new.md) | 030–034: What's new, built from git and the stories, and "Fixed in this build" |
| [05-pairing.md](05-pairing.md) | 040–041: pairing a device from Larry's link, one key for every app, re-pairing when it expires |

The persona is the same in all three apps: one person who uses the app every day on a phone, an iPad or a Mac, and the agents that fix what that person reports.

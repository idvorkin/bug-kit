# Logging conventions that make a log readable by the next session

The README's principles say what to log: instrument before theorizing, log silent passes, add a status line. This page covers how an app keeps its log usable by an agent that did not write it. Each rule comes from one of the apps' special sauce (2026-10-10).

## Keep an event catalogue, and edit it in the same commit

- Keep one table in `docs/DEBUGGING.md`, one row per subsystem, listing every event type, its fields, and the issue that made it.
- A new event, or a changed field, edits its row **in the same commit**.
- Reviewers check a new event against the table.

Without the table, the next session greps the source to learn what the log can say, and instrumenting first only pays off if the next agent knows the events exist. Sources: EA `docs/DEBUGGING.md` "Event catalogue"; CG `docs/DEBUGGING.md` and its same-change rule.

BugKit's own events are `bug_report_open`, `bug_report`, `bug_report_cancel`, `shake`, `bug_hook`, the `dictation_*` events, `logs_pruned`, `crash_report`, the `ui` actions of What's new, and `error` with `where`. Copy them into the app's table. A line that cannot be written (full disk, dead descriptor) is dropped, never raised; the next line that lands is preceded by `error` with `where: "session_log"` and `dropped`, the count lost. That note starts on a fresh line, so a partial line left by the failed write ends on its own line instead of swallowing the note, and a blank line can appear there.

## One `ui` event per user action, with `from:`

- Every action a person takes logs `ui` with an `action` and a `from` (home, hook, shortcut, tap, drag, file).
- `jq 'select(.type=="ui")'`, or `scripts/log-tool.sh summary <log>`, then replays the session.
- `from` tells a scripted launch (a simulator hook) apart from a person.

Source: CG's `ui` events.

## Name the logic version in `session_start`

An app that stores derived results (counted reps, analysed sets, computed summaries) puts its logic version on the first line:

```swift
let log = SessionLog(prefix: "swing", fields: ["build": "…", "analysis": .int(AnalysisVersion.current)])
```

Any change to that logic bumps the version, in the same commit, and stored results older than it re-run themselves. A report then says which logic produced what the person saw. Source: EA `session_start` `analysis`, and the rule in EA's AGENTS.md.

## Give a status screen the same numbers as the status line

A subsystem that can go quiet (sync, a watch link, a call) gets two things:
- a periodic status line in the log;
- a small in-app status screen that shows the same counts, plus a short ring of recent events and a button that forces one pass.

The person can then read "uploaded 3, waiting 2" on the device while the agent reads the same numbers in the log. Source: EA's Sync status screen with its 30 s `sync_status` line (EA #231).

## A companion device's events ride in the main log

A watch or widget cannot write the phone's file. Forward its events to the phone and log them there as `watch_<type>`, with the companion's own wall time in a field (`watch_t`). One file per launch then holds both devices' story in order. Source: EA `WatchBridge` (EA DEBUGGING.md). BugKit does not ship the bridge; the convention is what matters.

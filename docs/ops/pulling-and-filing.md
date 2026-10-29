# Pulling reports off devices, and filing each once

## What is on the device

Every app uses the same layout in its data container:

| Path | What |
|---|---|
| `Documents/logs/<prefix>-<yyyyMMdd-HHmmss>.jsonl` | one session log per launch (`{"type", "t", …}`), pruned after 30 days unless a report names it |
| `Documents/bugs.jsonl` | one line per report |
| `Documents/bugs/<stamp>/` | the report's screenshot and extra files |
| `Documents/crashes/` | MetricKit payloads `<stamp>.json`, plus the app's own `signal-<epoch>.txt` and `exception-<epoch>.txt` |

Also copy any system inbox the app depends on. EA found 12 undelivered WatchConnectivity transfers in `Documents/Inbox/com.apple.watchconnectivity/` (EA #197). List such folders in the app's `pull_extra` and `pull-reports.sh` copies them next to `logs/`.

## The copy

```sh
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier <bundle-id> --source Documents/logs --destination <dir>/logs
xcrun devicectl device copy from --device <id> --domain-type systemCrashLogs --source / --destination <dir>/system
```

- **Directories:** a directory source lands as a directory with the destination's name.
- **Find devices with `xcrun devicectl list devices --json-output <file>`.** Take physical iPhones and iPads, and name them by `hardwareProperties.marketingName`. Never commit a device id. CG keeps its ids in gitignored `*.local` files read by `devices.sh` (CG PR #241). BugKit's scripts need no ids at all.
- **Locked devices:** the copy works over the local network while the device is locked, if it has been unlocked once since boot. Verified 2026-10-10 against a phone with `passcodeRequired: true`. `xcrun devicectl device info lockState --device <id>` tells you which state the device is in.
- **Reachability:** the first copy is the reachability probe. Later copies of `bugs/` and `crashes/` may fail only because nothing exists yet, which is not an error (CG `pull-logs.sh`).
- **Noise:** "No provider was found" lines are noise.
- **"socket was closed unexpectedly"** means the device was busy or locked. Run again.
- **The current session's log** is copied as it stands, partly written.
- **A failed copy must stop a script that processes what it copied**, or a stale copy is processed as new (EA `pull-tracks.sh`).

`scripts/pull-reports.sh` does all of this for every app and device into `~/tmp/agent/bugs/<app>/<device>/`, the same tree the listener uses.

## Checking for unfiled reports

`scripts/pull-reports.sh --check` copies only `bugs.jsonl`, and, when CloudKit is configured as the listener has it
(`cloudkit_config`, or an inline `cloudkit` block), also reads CloudKit:
- It prints one line per report that has no issue yet: `new <app> <device> <reported_at> <note>`, with `cloudkit` as
  the device for a report waiting in CloudKit.
- CloudKit is read read-only through the listener's signed reader, into its own cache (`<root>/.cloudkit-check`),
  never the listener's inbox. Reports already downloaded are not fetched again. A CloudKit report counts as filed when
  its `bug-id:` or `bug:` marker is in an issue. A report found on a device and in CloudKit (mirrored delivery) is
  listed and counted once, as the device line, matched by `id`, else by `reported_at`. With no paired device, the
  check still reads CloudKit.
- The issue lookup reads up to 10,000 issues per repository. A repository that fills that read
  may have older issues cut off, so the check treats it as a failed lookup (exit 2) rather than trusting a partial
  marker list.
- The exit code is 1 when there are new reports, 0 when clean, 2 when the issue lookup, the CloudKit config or the
  CloudKit read failed, and 3 when it would read clean but the listener's `status.json` shows no poll for three poll intervals: a quiet
  check cannot hide a stopped listener. `scripts/bugs-monitor.sh` prints `listener_stale` once for that.

Give a check like this a stable, machine-readable line. CG's monitor matched `new:` and went silent forever when the check's output changed to `new (<device>):` (after CG PR #241).

## Filing once

Each issue body carries `<!-- bug:<reported_at> -->`. BugKit reports also carry `<!-- bug-id:<id> -->`. Filing skips a report whose marker is already in an issue.

- **A failed look at the existing issues stops the filing.** Otherwise everything would be filed again (CG 6fed157).
- **The title** is the note's first line that has words, with list bullets stripped and cut to 80 characters (CG 002e088).
- **Never upload the screenshot to a public repo.** Name its path on the Mac (CG 509da33). EA's older script hosted images on a gist.
- **The same report pulled from two folders is filed once.** Add each filed marker to the in-memory list straight away (CG `file-bugs.sh`).
- **The apps' marker dedupe has holes:**
  - An issue filed by hand, or by an older script, without the marker is invisible to it. CG's report of 2026-10-08T04:00:59Z still shows as unfiled although an issue was said to cover it (#233).
  - So the listener also matches a note whose first 60 characters already appear in a marker-free issue, and logs `possible_duplicate`. It may be the same bug reported again, so it is not dropped: the evidence is pulled and the report is commented on that issue as "Seen again", reopening it if it was closed as completed (not if closed as not planned or a duplicate). A report made before the issue was opened is the one someone filed by hand, so it counts as already filed.
  - When you file a report by hand, paste the marker.
- **Older lines can be invalid JSON.** EA's older notes could hold a raw newline, which splits one report over two lines. Readers log and skip such lines, never die on them, and split only on `\n`: Python's `splitlines()` also breaks on U+2028, which JSON allows inside a string.
- **beads instead of GitHub:**
  - MM files with `bd create "<title>" -t bug -p 2 -l from-app -d "<description>"` and writes the bead id back into the report.
  - The listener does the same through `bd create --json` in the app's repo.

## After filing: the fix

These steps come from EA and CG DEBUGGING.md and from MM AGENTS.md.

1. Find or write the user story the report belongs to. A bug gets an `Issues:` line; a request becomes a story.
2. Open the named log at the report's `session_t_ms` with `scripts/log-tool.sh at <log> <session_t_ms> 5`. Use `around <log> 15:10:00 10` when someone names a wall time, `summary <log> --drop frame` to skip per-frame noise, and `errors` or `types` for an overview. Put what it shows on the issue as a comment.
3. If the log cannot explain it, add the event that would, deploy, and wait for the next report. Never ship a guessed fix.
4. Make one commit per issue, verified on the cheapest rung. Close the issue once the build is on the device, with a comment naming the rung and the log line that proves the fix.

## Video and screenshots: a cheaper model looks, the driving agent reads text

A report from a camera or video app often needs frames looked at. Images are the most expensive thing an agent can read. At MM, one Sonnet review of frames cost about 91k tokens.

- **Frames never go to the driving agent.** A cheap vision model, or a read-only subagent on a small model, describes them, and the driving agent reads the descriptions (MM AGENTS.md; EA AGENTS.md "delegate the eyes, keep the text").
- **Name frames by wall-clock time** (`frame-15-10-04.250.jpg`) and extract only a window (`--from 15:10:00 --to 15:10:10`). With `wall` on every log line, a log time gives a frame range, and a frame's name gives a log slice (MM `frames.py`).
- **Ask narrow questions against a rubric.** For example, "are both hands on the handle: yes, no or unclear", written in a file and kept with the scripts (MM `hands-rubric.txt`). Write the answers to a CSV, resumable, so a rerun skips the frames already described.
- **Sample coarsely first,** one frame every second or two, and then take short dense runs around what changed (EA DEBUGGING.md).
- **Cache the descriptions** next to the frames, so the next session reads text, not the frames again.

The extraction and description scripts stay per app; this is the rule.

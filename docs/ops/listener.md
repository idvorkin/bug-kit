# Running the listener

[Back to BugKit](../../README.md) · [Operations](README.md).

`listener/bug-listener` is a [uv](https://docs.astral.sh/uv/) script that uses Typer. uv installs its dependencies
on first run. It needs Xcode's `devicectl` with each device paired, `gh` logged in for GitHub trackers, and `bd`
for beads.

### Configure

Copy the example to `~/.config/bug-kit/apps.json` and edit it. Only `apps.example.json` is in the repo.

```sh
mkdir -p ~/.config/bug-kit ~/tmp/agent/bugs
cp listener/apps.example.json ~/.config/bug-kit/apps.json
```

Each app needs:

- `name`, the folder name under `~/tmp/agent/bugs/`;
- `bundle`, the bundle id;
- `repo`, the local checkout;
- `tracker`, one of `{"kind": "github", "repo": "owner/name"}`, `{"kind": "beads"}` (filed with `bd create` in
  `repo`), or `{"kind": "none"}` (inbox and notification only).

Optional: `log_dir` (default `Documents/logs`, for older reports whose `log` is a bare file name) and `crash_dir`
(default `Documents/crashes`). The top-level `poll_seconds` defaults to 300. Commands below run from the repository root. A dry run still copies files and writes `listener.log`; it leaves tracker, seen-store, inbox and notifications unchanged.

### Local Mac apps

Set `mac_dir` on a Mac app entry to the **storage root containing `bugs.jsonl`**, not its `bugs` subdirectory:

```json
{
  "name": "example-mac",
  "bundle": "com.example.MacApp",
  "mac_dir": "~/Library/Application Support/com.example.MacApp",
  "tracker": { "kind": "github", "repo": "owner/mac-app" }
}
```

This entry reads the local Mac store instead of trying to pull that bundle from iOS devices. Other entries
continue polling paired devices. A Mac-only configuration needs no `devicectl` or reachable iPhone/iPad.
CloudKit intake remains available for the same app and shares its bundle+report-ID delivery receipts.

BugKit's updated Mac defaults use Application Support/<bundle ID>, or the executable name for an unbundled
app such as `lcd-timer` ([Mac adoption](../integration.md#macos-storage-and-command-line-tools)). For an
existing custom store, use its actual root instead: Magic Monitor can keep
`~/Library/Application Support/MagicMonitor`. Reports, screenshots, extra files, logs and crashes are copied
to `~/tmp/agent/bugs/<name>/mac/` before filing/inbox handoff. The app's source files are never moved or marked.
`log_dir` and `crash_dir` retain their device defaults; the local lane strips the leading `Documents/`, so
they resolve to `logs` and `crashes` beneath `mac_dir`. Report evidence paths stay relative to that root.
Missing required evidence is retried; paths escaping the root and nested evidence symlinks are rejected.
Listener state and `mac_dir` must not overlap.

First contact baselines existing reports and crashes, just like the device lane. To retire an app's own
Mac filing script, stop it before handing filing to the listener and preserve both its tracker history and
the listener's seen/inbox files. Preview `--once --dry-run --backfill` for unfiled old reports, then use
`--once --backfill` only for history that still needs filing. GitHub UUID markers and shared listener
receipts prevent refiling; Beads stopgaps that did not write listener receipts need their old history
baselined instead of blindly backfilled. Magic Monitor can then remove its Mac-only `scripts/file-bugs.sh`.
Check a newly saved local report reaches both the tracker and inbox once before removing the stopgap.

`mac_store` log events and `status.json.mac_stores` expose root reachability; `doctor` checks local roots
without filing. A successful Mac-only poll counts as reachable even when no device is paired.

Set `app_group` to an App Group identifier such as `group.com.example.voicekeyboard` when that app stores its evidence in the group's `Documents` directory. Every index, report-folder, log and crash copy then uses `devicectl`'s `appGroupDataContainer` domain with the group identifier. Without it, copies use `appDataContainer` with the bundle ID as before. `bundle` still identifies the app for reports and tracker configuration. The selected group must belong to the installed app and be accessible on the paired device; a wrong group or failed copy leaves evidence pending. The listener does not fall back to the app's private Documents. `scripts/pull-reports.sh` reads the same entry: its `--check`, `bugs.jsonl`, report-folder, log, crash and `pull_extra` copies use the group too.

```json
{
  "name": "voice-keyboard",
  "bundle": "com.example.voicekeyboard",
  "app_group": "group.com.example.voicekeyboard",
  "tracker": { "kind": "github", "repo": "owner/voice-keyboard" }
}
```

Keep the `Documents/bugs.jsonl`, `Documents/bugs/`, `Documents/logs/` and `Documents/crashes/` layout inside the group. `log_dir` and `crash_dir` remain relative to the selected container. Use `--once --dry-run --backfill` to inspect an existing store, then `--once --backfill` to include historical reports. See [app setup](../integration.md#app-group-storage).

### What one poll does

1. It lists devices with `xcrun devicectl list devices --json-output`: physical iPhones and iPads only, named by
   model (`iphone-17-pro`, `ipad-air-11-inch-m3`).
2. It probes each device with `devicectl device info lockState`. That proves the device is reachable and records
   whether it is locked.
3. For each app, it copies `Documents/bugs.jsonl`. Each line's key is its `id`, or `reported_at` for older lines.
4. For each key not in `~/tmp/agent/bugs/seen.json`:
   1. it checks the tracker for the issue marker, because the app's own `just file-bugs` may already have filed
      it;
   2. it copies the report's folder, the session log it names to
      `~/tmp/agent/bugs/<app>/<device>/`;
   3. it files the report: for GitHub, the screenshot's local path is named, never uploaded;
   4. it appends a line to `~/tmp/agent/bugs/inbox.jsonl` and, if `herdr` is on PATH, sends
      `herdr notification show`.
5. Independently of the manual index, it copies the crash folder and files newly discovered diagnostic files with their session evidence.
6. If the named report folder or session log fails to copy, or filing fails, the report stays unseen and the next poll tries again. A missing crash directory is optional: an app may never have crashed. Repeated index lines are handled once per poll.

GitHub deduplication prefers UUID markers. Timestamp markers match legacy reports or issues that have no UUID; two UUID reports at the same timestamp remain distinct. The note-prefix fallback applies only to marker-free issues. The lookup currently reads at most 1,000 issues per repository.

The first time the listener meets an (app, device) pair, it marks every report already there as seen without
filing it, because the apps' own `just file-bugs` filed those. `--backfill` files them instead, and still skips
any that already have an issue.

Every step is a JSON line in `~/tmp/agent/bugs/listener.log`:

- `poll_start`
- `devices`
- `device` (reachable, locked, ms)
- `copy` (source, ok, ms, locked, stderr on failure)
- `index`
- `baseline`
- `report`
- `crash`, `crash_baseline`, `crash_unreadable`
- `evidence_pending` (named evidence failed to copy; retries next poll)
- `file` (outcome: `filed`, `already_filed`, `would_file`, `none` or `error`)
- `tracker_error`
- `notify`
- `poll_end`, with counts

A poll that throws is logged with its traceback as `poll_error`, and the loop goes on. `--once` exits 1 when the poll reports failures or reaches no device; an offline paired device is not a failure while another device is reachable. `status.json` records the start, completion, last successful poll, device reachability and summary; pending delivery reasons are persisted in `seen.json`. Dry runs leave both files unchanged.

```sh
jq -c 'select(.event=="copy" and .ok==false)' ~/tmp/agent/bugs/listener.log   # every failed copy
jq -c 'select(.event=="poll_end")' ~/tmp/agent/bugs/listener.log               # one line per poll
```

### Run it

```sh
listener/bug-listener --once --dry-run   # copy and print what it would file; files nothing; leaves seen-store and inbox unchanged
listener/bug-listener --once             # one real poll
listener/bug-listener                    # forever, every poll_seconds
listener/bug-listener --interval 60      # while someone is actively testing
listener/bug-listener --once --dry-run --backfill   # what first contact would file without the baseline
```

**In a Herdr pane.** Open a pane in the driver's workspace and run `~/gits/bug-kit/listener/bug-listener`. The pane
shows one short line per step. Notifications come from `herdr notification show`.

**Under launchd.** Save this as `~/Library/LaunchAgents/com.example.bug-listener.plist`, replacing `YOU` with your
user name, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.bug-listener.plist`. PATH
must reach `uv`, `gh`, `bd` and `herdr`. A login agent (gui domain) is required, because `gh` reads its token from
the login keychain.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.example.bug-listener</string>
  <key>ProgramArguments</key>
  <array><string>/Users/YOU/gits/bug-kit/listener/bug-listener</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/YOU/tmp/agent/bugs/launchd.out</string>
  <key>StandardErrorPath</key><string>/Users/YOU/tmp/agent/bugs/launchd.err</string>
</dict>
</plist>
```

Stop it with `launchctl bootout gui/$(id -u)/com.example.bug-listener`.

## Automatic crash discovery

Crash polling runs independently for every reachable app/device pair, even if `bugs.jsonl` is absent, malformed or cannot be copied. It recognizes BugKit's `signal-<epoch>.txt`, `exception-<epoch>.txt`, their `.reported.txt` variants, and MetricKit `<yyyyMMdd-HHmmss>.json` payloads containing crashes or hangs.

Each diagnostic file gets a stable `crash:<sha256>` identity from its app bundle, device ID and canonical filename. The on-device `.reported.txt` rename does not create a second issue. A MetricKit payload containing several diagnostics becomes one issue; it is not automatically merged with an earlier signal report. Crash deduplication uses its ID, never a manual report's timestamp or note.

Manual reports use `keys` in `seen.json`; crashes use `crash_keys`. Each stream establishes its own baseline on its first successful snapshot. Pass `--backfill` to file that initial snapshot. A confirmed missing crash directory counts as an empty baseline, so the first crash appearing later is filed. An unreachable device or failed copy does not establish a baseline. On upgrade, pass `--backfill` before the first crash snapshot if historical crash files should be filed.

For a new crash, the listener also pulls the configured log directory. Signal and exception timestamps select the latest `session_start.started` at or before the crash and include `session_t_ms`, with `session_match` explicitly marked as inferred. Logs without that metadata and MetricKit payloads have `session_match: unknown`; their available logs remain on the Mac. A failed log copy leaves the crash pending; a confirmed absent log directory allows filing with evidence marked unavailable.

Each filed crash also has a local `<diagnostic-name>.report.json` sidecar containing its ID, evidence paths, inferred session and diagnostic metadata for agents.

Diagnostic contents and logs stay local. Issues contain their paths, diagnostic kind/counts and available build metadata. A failed fresh copy never scans stale local files.

## Doctor and status for agents

```sh
listener/bug-listener doctor --json
listener/bug-listener status --json
listener/bug-listener --config /path/to/apps.json doctor --json
```

Both commands return one JSON object with `schema_version: 1` and `ok`. Omit `--json` for readable terminal output. `--config` also works after the command name.

`doctor` checks configuration, a writable state directory, readable state files, availability of `devicectl`, device reachability/pairing, GitHub authentication and issue-read access, or the local beads repository. Missing devices and optional Herdr notifications produce warnings. It probes devices and reads trackers, but does not file issues, copy report evidence or send notifications. GitHub read access does not prove issue-create permission. Exit codes: 0 for no errors (warnings may remain), 1 for a failed check.

`status` reads local state without contacting devices or trackers. Its output includes `last_poll_started`, `last_poll_completed`, `last_successful_poll`, `in_progress`, device results, the poll summary and `pending`. Pending items name the app, device, report key, first/last attempt and reason (`evidence`, `crash_logs`, `tracker_lookup`, `tracker`, `inbox` for a filed report whose inbox line is not yet written, or `cloudkit_evidence` for a CloudKit download whose files do not match its manifest). A report clears from pending after successful delivery or a matching existing issue.

A status becomes stale after two polling intervals without a completed poll. The last actual interval is persisted, including `--interval` overrides. Exit codes: 0 for a recent healthy poll with a reachable device and no pending delivery, 1 for stale/never-run/failed/pending status, 2 for unreadable or invalid configuration/state. `in_progress` records an unfinished poll, including if a process dies mid-poll; it does not prove a process is still alive.

## CloudKit intake without reachable devices

For end-to-end CloudKit delivery, set `cloudkit_config: "~/.config/bug-kit/cloudkit.json"` in apps.json and build
its provisioned headless Mac reader. See [the per-app and Mac setup](../integration.md#private-cloudkit-delivery).
A poll runs the helper first, bounds it to 180 seconds, consumes complete downloads from the config's `inbox`
and then tries devices. No paired device and failed device discovery cannot prevent cloud intake; a discovery
failure is counted as an error. Failed cloud sync cannot prevent device fallback or consuming earlier complete
downloads, but remains an error in health/status. Configure one listener per state/inbox and run it in the
Mac's login session.

Cloud events: `cloudkit_poll`, `cloudkit_downloaded` (key/bundle), `cloudkit_report_pending` (key = the failed
report UUID, or null when the record name is not a UUID; reason = `download or evidence validation failed`,
`listing failed or record metadata is invalid` or `unknown`), `cloudkit_sync` (ok/rc/ms), `cloudkit_report_error`
and `devices_error`, then the existing `file` and new `inbox` event for each successful handoff. Sync output/error codes are sanitized; account/record contents are not logged. Downloads
have no first-contact baseline: apps upload only reports saved after opt-in, so the configured apps' first
reports are filed immediately. Unknown app bundles
are retained locally until configured. Delivery receipts are shared with device pulls by bundle + UUID; local
inbox history recovers receipts after a lost seen-store write. A failed inbox append leaves an `inbox` pending
reason and retries without filing another issue. Do not delete receipts, download folders or cloud records as
routine cleanup.

`doctor` runs `--check-signing` on the helper without contacting CloudKit. It cannot prove iCloud login,
network, schema/index or cellular delivery. `status.json.cloudkit` contains the last actual sync result;
`--once` returns non-zero on failed sync even if earlier downloaded reports are filed. Dry runs do not launch
the CloudKit helper. For a live check, require a phone report's UUID in both the tracker and Mac inbox within
one poll after a cellular upload; a local report that never reaches the Mac is failure.

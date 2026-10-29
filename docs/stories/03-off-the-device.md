# Getting reports off the device

Part of the [BugKit stories](README.md).

---

### User Story 020:

- **Summary:** Pull every app's reports and logs off every device at once (technical)
- **From:** EA `just pull-logs`; CG `pull-logs` for the phone and the iPad (PR #241, story 143)
- **Status:**
  - `scripts/pull-reports.sh` was verified on 2026-10-10 against an iPhone and an iPad: `--check` listed 6 unfiled reports, and folders were per app and device.
  - Its line handling was verified by hand on a broken fixture.
  - `pull_extra` (EA #197's WatchConnectivity inbox) is verified on the host by `scripts/tests/test_pull_reports.py`,
    with a stub `devicectl`. A real watch inbox is a device check, still to do.

#### Use Case:
- **As an** agent starting a bug pass
- **I want to** pull the logs, reports and crash files of every app from every reachable device in one command
- **so that** no device's reports sit unread because it was not the default one

#### Acceptance Criteria:
- **Scenario:** Two devices, two apps
- **Given:** a phone and an iPad are paired, and one of them is locked
- **When:** I run `scripts/pull-reports.sh`
- **Then:**
  - each app and device gets `~/tmp/agent/bugs/<app>/<device>/` with `logs/`, `bugs.jsonl`, `bugs/` and `crashes/`;
  - a device that cannot be reached is named and skipped;
  - a locked device that has been unlocked once since boot still copies.

- **Scenario:** Files the app has not taken yet
- **Given:** EA's config lists `Documents/Inbox/com.apple.watchconnectivity` in `pull_extra`
- **When:** I run `scripts/pull-reports.sh`
- **Then:**
  - the device's folder also has `com.apple.watchconnectivity/` with whatever the watch sent and the app has not taken;
  - a listed folder that is missing is named, and the rest still copies.

- **Scenario:** A quick look
- **When:** I run `scripts/pull-reports.sh --check`
- **Then:**
  - only `bugs.jsonl` is copied;
  - each unfiled report prints as `new <app> <device> <reported_at> <note>`, and the exit code is 1;
  - a failed issue lookup exits 2 instead of calling everything new.

---

### User Story 021:

- **Summary:** A report becomes an issue once (technical)
- **From:** EA `file-bugs` (#24); CG story 143 (509da33, 6fed157, 002e088); MM story 041 (beads)
- **Status:**
  - `listener/bug-listener` `Filer` checks the GitHub markers and the note text before copying and before filing.
  - Verified on the host by the pytest tests for issue bodies, titles, distinct UUIDs at one timestamp, legacy markers, and cached UUIDs after creation.
  - Dry runs on 2026-10-10 skipped 160 reports that were already filed. A real `gh issue create` has not run yet.

#### Use Case:
- **As a** developer with devices near the Mac
- **I want to** have every new report filed with its note and context, and told where its screenshot is on the Mac
- **so that** nothing is lost, nothing is filed twice, and no picture lands in a public issue

#### Acceptance Criteria:
- **Scenario:** Filing after a session
- **Given:** two reports are on the device, and one is already an issue (its body has `<!-- bug:<reported_at> -->`)
- **When:** the listener polls
- **Then:**
  - exactly one issue is created, with the note, the screen, the build, the log's path and moment, the screenshot's path on the Mac, and both markers;
  - no picture is uploaded;
  - the next poll files nothing.

- **Scenario:** A report filed by hand, without the marker
- **Given:** a marker-free issue body already holds the note's first 60 characters
- **Then:**
  - the listener logs `possible_duplicate` and files no new issue;
  - it still pulls the report's folder and session log, and comments "Seen again" on the matched issue with the device, build, local paths and the report's markers, reopening the issue if it was closed as completed;
  - the inbox line carries `seen_again: true` and the comment's URL as `ref`; the next poll comments nothing.

- **Scenario:** The issue lookup fails
- **Given:** `gh issue list` fails
- **Then:** nothing is filed, the log has `tracker_error`, and the report stays unseen for the next poll

- **Scenario:** Two UUID reports share a timestamp or note
- **Given:** an issue already carries one report's UUID marker
- **Then:** a different UUID is still filed, even if its timestamp or note matches

- **Scenario:** A repeated index line
- **Given:** the same report appears twice in bugs.jsonl
- **Then:** it creates one issue or inbox entry per poll

---

### User Story 022:

- **Summary:** An always-on listener (technical)
- **From:** the bug-kit proposal ("an always-on listener that checks for new bug reports on the iPad or the iPhone"); EA and CG `bugs-monitor.sh`
- **Status:**
  - `listener/bug-listener`. `--once --dry-run` was verified against both devices on 2026-10-10. Running it forever in a Herdr pane or under launchd has not been run for long yet.
  - `scripts/bugs-monitor.sh`, for an agent driving a test session (EA's, generalized). It is verified on the host by `scripts/tests/test_bugs_monitor.py`. As a live Monitor against a device it is still to run.

#### Use Case:
- **As the** person reporting from whichever device is at hand
- **I want to** have each report filed and the driver told within minutes, with nobody remembering to pull
- **so that** a report from the iPad is as good as one from the phone

#### Acceptance Criteria:
- **Scenario:** A new report on the iPad
- **Given:** the listener runs with the default 300 s interval
- **When:** I shake the iPad and log a report
- **Then:**
  - within one poll the report's folder, its session log and the crash folder are on the Mac;
  - an issue exists, a line is in `inbox.jsonl`, and a Herdr notification is shown.

- **Scenario:** Named evidence fails to copy
- **Then:** the report stays unseen, `evidence_pending` is logged, and the next poll retries before filing
- **And:** an absent crash directory does not block filing when an app has never crashed
- **Verification:** host pytest `test_poll_retries_required_evidence_and_files_duplicate_lines_once`

- **Scenario:** First contact
- **Given:** the listener has never seen this app on this device
- **Then:** every report already there is marked seen without filing, unless `--backfill` was passed
- **And:** for a GitHub-tracked app, a report with no issue yet is filed rather than marked seen

- **Scenario:** An agent is testing with the person
- **Given:** the agent armed `scripts/bugs-monitor.sh <app>` as a persistent Monitor
- **When:** the person logs a report on either device
- **Then:**
  - the agent is woken with one `new …` line, and never again for that report;
  - if the check cannot run, the agent gets one `check_failed` line rather than silence, and `check_ok` once it recovers.

---

### User Story 023:

- **Summary:** The listener's own log answers "did it run, and what did it see" (technical)
- **From:** the log-before-theorizing feedback (2026-10-09, "logs on everything")
- **Status:** `listener.log` JSON Lines. Verified on the host by `test_index_tolerates_broken_lines_and_keeps_u2028`, and in the dry runs.

#### Use Case:
- **As a** developer asking why a report was not filed
- **I want to** read every poll, device, copy, report and outcome
- **so that** a missing issue is explained from the log

#### Acceptance Criteria:
- **Scenario:** A broken line
- **Given:** an older app wrote a note with a raw newline, so one report spans two lines
- **Then:** both fragments are logged as `line_unreadable` with their line numbers, and the other reports are read

- **Scenario:** A report that uses U+2028
- **Given:** a note holds U+2028, which JSON allows raw inside a string
- **Then:** the line is read whole, not split

---

### User Story 024:

- **Summary:** Screenshots never leave the Mac for a public repo (technical)
- **From:** CG story 143 (509da33)
- **Status:** `issue_body` names the path and embeds no image. Verified on the host by `test_issue_body_names_the_screenshot_and_carries_both_markers`.

#### Use Case:
- **As someone** whose screen may show health data, places or a journal
- **I want to** have the issue say where the screenshot is on the Mac, not show it
- **so that** a public repo never carries my screen

#### Acceptance Criteria:
- **Scenario:** A report with a screenshot
- **When:** it is filed to a GitHub repo
- **Then:** the body has "`~/tmp/agent/bugs/…/screen.png` on the Mac, not uploaded" and no image link

---

### User Story 025:

- **Summary:** Before fixing, read the log at the report's moment (technical)
- **From:** EA DEBUGGING.md (steps 4 and 5); CG DEBUGGING.md; MM AGENTS.md
- **Status:**
  - A practice, described in [the principles](../principles.md) and [../ops/pulling-and-filing.md](../ops/pulling-and-filing.md). There is no code to test.
  - Saving the evidence before a relaunch (MM's `grab.sh`, mmn-1ui) is a rule in [../ops/deploying.md](../ops/deploying.md). MM's recipes follow it; EA's and CG's do not yet.

#### Use Case:
- **As an** agent picking up a filed report
- **I want to** open the named log at `session_t_ms`, and the story the report belongs to
- **so that** the fix starts from evidence, and the spec gains the story if it had none

#### Acceptance Criteria:
- **Scenario:** A new issue
- **Given:** an issue from the listener
- **When:** I start on it
- **Then:**
  - I comment with what the log shows at the moment;
  - I fix it in one commit that names the issue, on the cheapest rung that can see it;
  - I close it with the rung named once the build is on the device.

- **Scenario:** "That just happened"
- **Given:** the person says something went wrong a moment ago, and I am about to rebuild
- **When:** I relaunch or reinstall the app
- **Then:**
  - the newest session log and the app's rolling buffer were copied to a timestamped folder first;
  - the copy names the wall-clock span it covers, so the log can be sliced at the person's time.

---

### User Story 026:

- **Summary:** Discover crash and hang evidence without waiting for a manual report
- **From:** BugKit agent workflow, 2026-10-10
- **Status:** Listener host tests cover missing/unreadable manual indexes, independent baselines, backfill, log-copy retries, renamed-file deduplication and MetricKit hangs. Real-device crash discovery remains unverified.

#### Acceptance Criteria:
- A signal, exception or MetricKit diagnostic is discovered independently of `bugs.jsonl`.
- Each diagnostic file is delivered once through the configured tracker/inbox; `.reported.txt` renames keep its identity.
- Initial snapshots are baselined unless `--backfill` is passed; absent folders establish an empty baseline, failed copies do not.
- Preceding session selection is explicitly marked as inferred; an unknown session is never presented as certain.
- Failed evidence or tracker operations remain pending for later polls.

---

### User Story 027:

- **Summary:** Agents can check listener setup and health as structured data
- **From:** BugKit agent workflow, 2026-10-10
- **Status:** Host CLI tests cover old polling flags, doctor JSON, authentication checks, invalid configuration, stale/healthy/never-run status, offline paired devices with and without a reachable device, pending evidence and corrupt state.

#### Acceptance Criteria:
- `doctor --json` checks setup and read access without filing or notifying.
- `status --json` reports last completion/success, staleness, reachability and pending reasons without external calls.
- Exit codes allow agents to distinguish healthy, unhealthy and unreadable state.
- A dry run does not update seen-state, inbox or health timestamps.

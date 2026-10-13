# Runners: what keeps watching while nobody is

## The listener (always on)

`listener/bug-listener` polls every device and app every 5 minutes. It files each new report once, writes `inbox.jsonl`, and sends a Herdr notification. Run it in a Herdr pane, or under launchd (see [listener setup](listener.md)).

The listener replaces the per-app monitors below for filing. Those are still useful while an agent is testing with the person.

## Monitor rather than `/loop`, while someone is testing

EA and CG each had `scripts/bugs-monitor.sh`, which runs the bugs check every minute and prints one line per new report, each report once. Arm it as a persistent Monitor:

```
Monitor(command: "scripts/bugs-monitor.sh", description: "new shake reports on the phone", persistent: true)
```

A Monitor wakes the model only when a report appears. `/loop 5m just bugs-check` wakes it every five minutes to find nothing, so it is the fallback when Monitor is not available.

With BugKit, the command is `scripts/bugs-monitor.sh [app]`. It runs `pull-reports.sh --check` every minute and prints:
- `new <app> <device> <reported_at> <note>`, once per report;
- `check_failed <reason>`, once, when the check cannot run (devicectl, or the issue lookup), so a broken check is not mistaken for silence;
- `check_ok`, when it recovers.

An app's justfile finds BugKit without a path of its own, as EA's `bugs-check.sh` does: first `BUG_KIT`, then the SwiftPM checkout a build leaves, then `~/gits/bug-kit`.

```sh
bug_kit() {
  for k in "${BUG_KIT:-}" Build/SourcePackages/checkouts/bug-kit "$HOME/gits/bug-kit"; do
    [ -n "$k" ] && [ -x "$k/scripts/pull-reports.sh" ] && { echo "$k"; return; }
  done
  echo "no BugKit checkout: build once, or clone it to ~/gits/bug-kit" >&2; return 2
}
"$(bug_kit)/scripts/bugs-monitor.sh" exercise-analyzer
```

The SwiftPM path depends on `-derivedDataPath`: EA's is `Build/`, CG's is `native/Build/`.

## Long builds and tests in the background

- **The Bash tool caps a foreground command at 10 minutes**, and `xcodebuild test` on a busy Mac runs longer. Run it with `run_in_background`, writing to a log file, and wait for the task notification.
- **If you poll a log for `TEST SUCCEEDED|FAILED`, delete or rotate it first.** A wait loop once matched the previous run's "TEST FAILED" (CG, 2026-10-07).

## The no-mistakes pipeline

no-mistakes is a local gate that takes committed work on a feature branch through these steps: intent, rebase, review, test, document, lint, push, PR, CI. Each repo configures it in `.no-mistakes.yaml` on main.

The local Test step is host-only: run the touched module's targeted host tests and read the diff. The full
regression suite runs once in CI. Repositories with no CI workflows may use `no_ci: true`; BugKit has CI.
Do not run the full `just test` immediately before the gate, or repeat live checks inside it.

The driving session owns simulator/device checks, performs them once during its explicit build turn,
and records the evidence and remaining physical-device checks in the PR body. The Test agent must not
boot a simulator, run xcodebuild, deploy, or file real reports. Run heavy commands under
`lockf -k -t 3600 ~/tmp/agent/locks/build.lock`; if an outer driver already holds that lock, do not
reacquire it in nested commands. Signing builds also take the signing lock described in `AGENTS.md`.

Gotchas from runs on 2026-10-07:
- **`axi status` reports only the checked-out branch.** After a branch switch use `axi status --run <id>`. A watcher left polling `status` looped for an hour.
- **`axi run` and `axi respond` return after an 8-minute hold** with `error: wait … elapsed`. That is not a failure: run them in the background and reattach.
- **"Test agent exceeded its invocation budget"** is a cut, not a test failure.
- **The pipeline refuses to start while untracked files are in the tree.** Put other agents' folders in `.git/info/exclude`.
- **A current run does not own a test simulator or xcodebuild.** Live tests belong to the driving session,
  separately from the host-only gate. Use status/logs to identify the active step; do not interrupt a
  healthy pipeline merely because the Mac is slow, or restart the daemon while runs are active.

## One agent, one simulator, at a time

- Several agents each booting simulators drove a 16 GB Mac's load average to about 950 and filled swap (2026-10-07). Since then only one agent runs at a time, with at most one simulator.
- Before handing over, check that nothing is left running: `xcrun simctl list devices booted` and `pgrep -x xcodebuild`.
- Agents end a turn with "DONE, simulator shut down".
- A bug-pass prompt that works: "Pull logs and reports off the phone and iPad, file an issue for each new report, fix (one commit per bug, verified on the cheapest rung), redeploy, then write an update to `~/tmp/agent/notes/bug-pass/<repo>.md`."
- Write commit messages with a quoted heredoc (`<<'EOF'`). An unquoted one once ran a backticked `just ipad` inside the message text, which started a signing build.

# Operating iOS apps from a Mac, with agents

This folder describes how Exercise Analyzer (EA), Context Grabber's native app (CG) and Magic Monitor (MM) are built, deployed, tested and debugged on real devices by coding agents that cannot see the screen. It is written generally: each page names where a rule came from, and every device id, team id and account is a placeholder.

| Page | What it covers |
|---|---|
| [logging.md](logging.md) | Event catalogue, input sources, logic versions, memory and companion-device events |
| [listener.md](listener.md) | Configure bug-listener, independent crash discovery, doctor/status JSON, retries, dry runs and launchd |
| [pulling-and-filing.md](pulling-and-filing.md) | Getting logs, reports and crashes off the phone and iPad; filing each report once; devicectl quirks |
| [runners.md](runners.md) | The listener, Monitor versus `/loop`, background builds, the no-mistakes pipeline, one agent at a time |
| [deploying.md](deploying.md) | Build once, install on the phone, the iPad and the watch; the signing lock; the BUILD SUCCEEDED rule; error 10002 |
| [signing.md](signing.md) | Keeping automatic signing working: which builds need the Xcode account, how to check, new devices, new capabilities |
| [simulators.md](simulators.md) | One named simulator at a time, launch hooks, privacy grants, editing preferences behind cfprefsd, erase needs shutdown |
| [test-ladder.md](test-ladder.md) | Host, simulator and device rungs, and naming the rung |
| [crashes-and-tools.md](crashes-and-tools.md) | Symbolicating MetricKit payloads, `.ips` reports, Instruments from the command line |

## Scripts

Pulling and deployment use `~/.config/bug-kit/apps.json`, the listener's file. What's new takes its repository and story settings through command-line options.

- `scripts/pull-reports.sh [--check] [app]`: pulls logs, reports and crash files from every device.
- `scripts/deploy-all.sh <app> [--only …] [--register dev] [--watch] [--dry-run]`: builds once under the signing lock and installs on every device.
- `scripts/ota-upload.sh <App.app> --name <prefix> [--repo dir]`: publishes an installed bundle to the over-the-air builds folder; `deploy-all.sh` runs it after every install ([deploying.md](deploying.md)).
- `scripts/whats-new.sh <out.json> --repo … --base-url …`: the What's new build phase.

## Sources

The rules come from these places:
- the apps' justfiles, `scripts/`, DEBUGGING.md, TESTING.md and AGENTS.md;
- chop-conventions `deployment/ios-device-signing.md` (PR #238) and `dev-inner-loop/` (PR #239);
- the mac-driver README;
- the agents' session notes from 2026-09 and 2026-10.

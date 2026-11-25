# Working in BugKit

BugKit is the shared repository for all of the apps. Besides the library, it holds the practices every app follows (README, "Shared practices for every app"). When a bug or practice found in one app applies to all of them, it belongs here.

Use Beads for all repository task tracking. Run `bd prime` at the start of a session and after context recovery, then `bd ready` or `bd list --status=in_progress`. Create a bead before new work, mark it `in_progress`, and close it only after the work and its required validation are complete. Link related GitHub issues with `--external-ref`; GitHub remains the intake for reports and the review surface for PRs.

All git worktrees share the main checkout's Beads database. Issue data lives in Dolt, outside code branches; `.beads/config.yaml` and `.beads/metadata.json` are tracked configuration. Use `bd dolt pull` and `bd dolt push` to sync issue data. JSONL exports are optional interchange files, not backups or the source of truth.

Every code or config change (including `.no-mistakes.yaml`, CI, entitlements and project settings) goes through no-mistakes before merge. Keep its pipeline fixes, follow its branch-sync instructions, and merge only after required checks pass and the user has authorized merging. Do not bypass it with a direct push. Docs-only changes skip the pipeline (Igor, 2026-10-18): README or docs text, a story Status line naming a commit, or a ledger row, whether a follow-up commit or its own PR, is pushed straight to the branch on `origin` (`git push origin <branch>`, not the no-mistakes remote). A follow-up that only names a commit or updates a status needs no new Codex round.

Only one simulator on this Mac at a time: before booting, check xcrun simctl list devices booted and wait until it's empty; shut yours down when done.

Only one build or simulator runs on this Mac at a time. Before new heavy work (xcodebuild, simulator tests, signed or unsigned reader builds), wait for an explicit build turn and run it under `lockf -k -t 3600 ~/tmp/agent/locks/build.lock <command>`. When an outer driver already holds `build.lock` for your invocation (it tells you so), do not take it again in nested commands: that deadlocks. Signing runs also hold `lockf -k -t 900 ~/tmp/agent/locks/xcode-signing.lock` from generation to launch, and inside it run the build as `"$BUG_KIT/scripts/signing-guard.sh" xcodebuild ... -allowProvisioningUpdates`; install only after the guard succeeds (docs/ops/signing.md).

Before starting any simulator or live test, run `xcrun simctl list devices booted`. If another agent has a device booted, wait. Use one disposable simulator, bound test commands, and shut it down when its test step ends. Avoid unbounded `tail -f` watchers. Use `/bin/ls` or `rg` instead of the inherited `ls` alias.

One pipeline run per train: finish the whole stack before the first push. Do not push while a run is in flight unless review or test asked for that fix. Never restart the no-mistakes daemon or reboot while runs are active.

Review settles in one fix round. In round 1, fix every error and warning together. In later rounds, fix errors only and decide info findings in one pass. Cap review at two rounds; file the rest as Beads issues, and retain any unresolved errors as merge blockers.

The pipeline Test step is host-only. The driving session owns simulator/device checks, runs them once under its build turn, and records the evidence and remaining physical-device checks in the PR body.

- **Apple docs and Simulator/Previews: follow the `ios-codev` skill** (Igor, 2026-11-24). It covers looking up Apple APIs on Sosumi before coding, and previews first, then the Simulator, from the CLI on the Mac only. Read [`skills/ios-codev/SKILL.md`](https://github.com/idvorkin/chop-conventions/blob/main/skills/ios-codev/SKILL.md) (lands with chop-conventions #275), or `~/.claude/skills/ios-codev/SKILL.md` once the skill is symlinked.

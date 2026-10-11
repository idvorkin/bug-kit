# BugKit issue tracking

BugKit uses Beads (`bd`) for agent work. The issue prefix is `bug`. GitHub reports and PRs link to beads through external references; the Dolt database is the task source of truth.

```sh
bd prime
bd ready
bd create "Describe the work" --type task --description "Why and acceptance criteria"
bd update <id> --status in_progress
bd close <id> --reason "What shipped and how it was verified"
bd dolt push
```

Every worktree uses the main checkout's `.beads/embeddeddolt` database. This directory is ignored by Git. Code commits carry configuration; `bd dolt push` and `bd dolt pull` sync the database to the configured GitHub Dolt remote. An ordinary code push does not sync tasks. JSONL exports are optional interchange, not backups.

On a fresh clone, initialize the local store from the existing remote (do not reinitialize an existing database):

```sh
bd init --prefix bug --remote git+https://github.com/idvorkin/bug-kit.git \
  --non-interactive --skip-hooks --skip-agents
bd dolt pull
```

This was verified with a fresh local clone recovering all three active beads. Existing clones use `bd dolt pull` directly.

See [agent instructions](../AGENTS.md) for validation and simulator coordination, and [the README](../README.md#beads-work-tracking) for clone setup.

## Tuesday pause handoff

The published release is **v0.3.1**. Start with the top bead **bug-e9y**; its description contains the full resume context, WIP branch references, verification evidence, ordered next steps and questions for Igor. Unvalidated WIP is preserved on `archive/pause-tuesday-*` branches and must pass no-mistakes before merge.

```sh
bd prime
bd dolt pull
bd ready
bd show bug-e9y
bd list --label needs-igor
```

The tasks live in the shared Dolt database. `pause-tuesday.jsonl` is a sanitized snapshot of the pause tasks for interchange and review; it is not a database backup or the source of truth. This handoff branch was committed and pushed under explicit pause instructions without starting a pipeline; validate any later PR before merging it.

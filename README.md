# handoff

A Claude Code plugin that ends a session with a short, structured note and starts the next session from that note, not from the old transcript.

- **`/handoff:handoff`** writes what's done, what's pending, blockers, key context (decisions, rejected approaches, gotchas), and the exact next commands.
- **`/handoff:pickup`** loads the note in a fresh session, checks it against the repository as it is now, and briefs you before doing anything.

## Why

`/resume` re-sends an entire earlier conversation to get you back to where you were. Most of that history is noise, and you pay for it on every turn after. A handoff note is a few hundred tokens of what actually matters. The same note also answers "where are we?" (`/handoff:pickup status`) without a long recap.

## Install

From GitHub (once published):

```
/plugin marketplace add <owner>/<repo>
/plugin install handoff@handoff
```

From a local clone:

```
claude plugin marketplace add /path/to/handoff
claude plugin install handoff@handoff --scope user
```

A local marketplace loads the plugin in place, so edits take effect after `/reload-plugins`.

Requires macOS or Linux (POSIX `sh`) and `git`. Windows isn't supported.

## Usage

| Command | What it does |
|---|---|
| `/handoff:handoff` | Write (or replace) the note for the current repo and branch |
| `/handoff:handoff <focus>` | The same, emphasising something ("stuck on the auth flake") |
| `/handoff:handoff done` | Archive the note. The work is finished and the startup hint stops. |
| `/handoff:pickup` | Load this branch's note and brief you, then wait for your go-ahead |
| `/handoff:pickup status` | Same as above. Use it to answer "where are we?" |
| `/handoff:pickup list` | List every note for this repo |
| `/handoff:pickup <branch>` | Load another branch's note |

When a new session starts (or after `/clear`) on a branch that has a note, a hook prints one line, e.g. `Handoff note for feat/login (3h old): … Run /handoff:pickup to load it.`

Both skills are user-invoked only (`disable-model-invocation`). Claude never writes or loads a note unless you ask.

## Drift check

`/handoff:pickup` doesn't trust the note blindly. The script compares it with the repo and reports:

| Flag | Meaning |
|---|---|
| `NEW-COMMITS` | Commits landed since the handoff (listed) |
| `REWRITTEN` | The recorded head was rebased, amended, or reset away |
| `UNCOMMITTED-CHANGED` | The working tree differs from the snapshot taken at handoff |
| `WORKTREE-MOVED` | The branch is now checked out in a different worktree |
| `OTHER-BRANCH` / `BRANCH-GONE` | You loaded another branch's note, or that branch no longer exists |
| `STALE` | The note is more than 7 days old |

## Where notes live

Notes are **never written into your repository** and never committed:

```
~/.claude/handoffs/<repo-slug>/<branch>.md
~/.claude/handoffs/<repo-slug>/archive/<branch>--<timestamp>.md
```

- `<repo-slug>` is the main repository's path, so every git worktree of one repo shares a folder, and each branch has its own note. Parallel worktrees don't overwrite each other.
- Detached HEAD uses `detached-<sha>`. A directory outside git uses `_nogit`.
- Saving over an existing note archives the old one first, and writes are atomic. Nothing is ever deleted.
- Set `CLAUDE_HANDOFF_DIR` to store notes somewhere else.
- While saving, Claude writes the note to a draft file in the repo's git dir (`.git/handoff-draft.md`, per worktree), or to `.handoff-draft.md` outside git. The script then moves it into the store. The note text never passes through a shell command, so Bash guard hooks that inspect commands don't block it.

Notes can contain paths, commands, and design context from your project. The handoff instructions forbid writing secret values, but treat the folder like any other local notes.

## Note format

```markdown
---
repo: /path/to/repo
worktree: /path/to/repo
branch: feat/login
head: 1a2b3c4
created: 2026-09-25T18:40:00+0530
created_epoch: 1790345400
goal: Session-cookie login replacing the token header
---
## Done
## Pending
## Blockers
## Key context
## Next commands
## Uncommitted
```

Claude writes the goal and the sections. The script fills in the frontmatter and appends a hidden git status snapshot that the drift check uses.

## Development

```
sh tests/run.sh                  # script tests in throwaway repos
TEST_SH=dash sh tests/run.sh     # run handoff.sh under another shell
shellcheck -s sh scripts/handoff.sh tests/run.sh
claude plugin validate .
```

CI (`.github/workflows/ci.yml`) runs shellcheck and checks the JSON manifests. It also runs the tests on Ubuntu, where `/bin/sh` is dash, and on macOS.

All logic lives in `scripts/handoff.sh`, and the skills only call it. There's no `evals/` suite, because both skills are user-invoked only, so trigger evals don't apply. `tests/run.sh` covers the behaviour.

## License

MIT. See [LICENSE](LICENSE).

---
name: pickup
description: Load the handoff note for the current repo and branch, check it against the repository as it is now, and brief the user before continuing the work.
argument-hint: "[status | list | <branch>]"
disable-model-invocation: true
allowed-tools: Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh" *)
---

# Pickup

Continue work from a handoff note written by `/handoff:handoff` in an earlier session.

## Note and drift report (captured when you invoked this)

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh" pickup "$ARGUMENTS"`

## Steps

1. If the output above is a list of notes and not a note (no note for this branch, `list` was asked for, or the branch name was invalid), show that list, mention `/handoff:pickup <branch>`, and stop.
2. Otherwise, brief the user in at most 10 lines:
   - **Drift first**, and only if the report shows any: `REWRITTEN`, `BRANCH-GONE`, `OTHER-BRANCH`, `WORKTREE-MOVED`, `STALE`, `NEW-COMMITS`, or `UNCOMMITTED-CHANGED`. Say what each one means for the plan. For example, a `REWRITTEN` head means commit SHAs in the note may no longer exist.
   - **Goal**: one line.
   - **Done**: one line.
   - **Next**: Pending #1, as written.
   - **Blockers**: or "none".
3. **Then stop and wait for the user.** Make no tool calls and don't run the Next commands until they say to continue. Treat the note as a claim about the past, and the drift report as what is true now.
4. Once the user says to go on, start from Pending #1, running the note's Next commands where they apply. Respect everything under Key context, especially rejected approaches.

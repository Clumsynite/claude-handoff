---
name: handoff
description: Write a structured handoff note (done, pending, blockers, key context, next commands) for the current repo and branch, so a fresh session can continue with /handoff:pickup instead of resuming this transcript.
argument-hint: "[focus text | done]"
disable-model-invocation: true
allowed-tools: Bash(sh "${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh" *)
---

# Handoff

Write a handoff note so a **fresh session with no memory of this conversation** can continue the work. The note replaces resuming this transcript, so whatever the next session needs has to be in it.

Arguments: $ARGUMENTS

## Repository state (captured when you invoked this)

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh" state`

## Steps

1. If the arguments are exactly `done`, the work is finished. Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh" clear`, report what it printed, and stop.
2. If this conversation has done no substantive work (nothing built, decided, or learned), say so and ask before saving. A new note replaces the current one for this branch. The old one is archived, not deleted.
3. Write the note in exactly this shape. Any other arguments are extra focus to emphasise.

   ```
   goal: <one line: what this line of work is for>
   ## Done
   - <finished work, with file paths and commit SHAs>
   ## Pending
   1. <the exact next step, specific enough to start without asking>
   2. ...
   ## Blockers
   - <what needs the user or outside input, or "none">
   ## Key context
   - <decisions made, and approaches rejected with the reason>
   - <gotchas, traps, and non-obvious facts about the code or environment>
   ## Next commands
   - `<exact shell command to run first: tests, build, dev server, ...>`
   ## Uncommitted
   - <each entry from the git status above, with what it is and whether it should be kept>
   ```

   Rules:
   - Keep it under 80 lines. Use concrete paths, SHAs, commands, and names. Write no narrative, and don't restate what `git log` already says.
   - Spend the most care on **Key context**. A fresh session can re-read the code, but it can't recover why something was chosen or what already failed.
   - **Never include secrets**: no values from `.env` files, passwords, tokens, keys, or credentials passed on a command line. Say where a secret lives, not what it is.
   - Pending #1 must be actionable as written.
   - The first line must be `goal: ...`. The script adds repo, branch, head, timestamps, and a git status snapshot itself, so don't write frontmatter.

4. Save it in two steps:
   1. Use the **Write tool** to write the note to the `draft path` shown in the repository state above. Don't pipe it through Bash: note text is full of commands, and shell guard hooks would inspect it.
   2. Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/handoff.sh" save --draft`. This moves the draft into the note store and deletes the draft.

   If it prints `handoff: not saved ...`, the draft is kept. Fix what the message names, rewrite the draft, and run `save --draft` again.

5. Reply in at most three lines: the saved path, the goal, and "Start a new session (or `/clear`) and run `/handoff:pickup`."

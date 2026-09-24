#!/bin/sh
# Self-contained tests for scripts/handoff.sh. Uses throwaway repos and a
# throwaway CLAUDE_HANDOFF_DIR; touches nothing else. Usage: sh tests/run.sh

HERE=$(cd "$(dirname "$0")/.." && pwd -P)
H="$HERE/scripts/handoff.sh"
# Shell that runs handoff.sh; set TEST_SH=dash (or bash) to test another /bin/sh.
SH=${TEST_SH:-sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/handoff-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT INT TERM

export CLAUDE_HANDOFF_DIR="$WORK/store"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_NOSYSTEM=1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "$2" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# check NAME OUTPUT PATTERN - OUTPUT must match the grep -E PATTERN.
check() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then ok "$1"; else no "$1" "$2"; fi; }
check_not() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then no "$1" "$2"; else ok "$1"; fi; }

# run DIR ARGS... - run handoff.sh in DIR, capturing output; asserts exit 0.
run() {
	d=$1
	shift
	OUT=$(cd "$d" && "$SH" "$H" "$@" 2>&1)
	rc=$?
	[ "$rc" -eq 0 ] || no "exit 0: $* (got $rc)" "$OUT"
}

note() {
	printf 'goal: %s\n## Done\n- thing\n## Pending\n1. next\n## Blockers\nnone\n' "$1"
}

save() {
	d=$1
	shift
	OUT=$(cd "$d" && note "$1" | "$SH" "$H" save 2>&1)
}

REPO="$WORK/repo"
git init -q -b main "$REPO"
(cd "$REPO" && echo a >a && git add a && git commit -qm first)
git -C "$REPO" branch -q 'feat/x'
git -C "$REPO" checkout -q 'feat/x'
git -C "$REPO" worktree add -q -b other "$WORK/wt2" main 2>/dev/null
WT2="$WORK/wt2"
SLUG=$(printf '%s' "$REPO" | sed 's#/#-#g')

echo "# slugs"
run "$REPO" state
check "state names the feat/x note" "$OUT" "note path: .*/$SLUG/feat\+x\.md$"
run "$WT2" state
check "second worktree shares the repo slug" "$OUT" "note path: .*/$SLUG/other\.md$"
check "state reports worktree" "$OUT" "worktree: $WT2"

echo "# save"
save "$REPO" "first goal"
check "save writes the note" "$OUT" "saved: .*/feat\+x\.md"
f="$CLAUDE_HANDOFF_DIR/$SLUG/feat+x.md"
check "frontmatter has branch" "$(cat "$f")" "^branch: feat/x$"
check "frontmatter has goal" "$(cat "$f")" "^goal: first goal$"
check "frontmatter has head" "$(cat "$f")" "^head: [0-9a-f]{7,}$"
save "$REPO" "second goal"
check "second save archives the first" "$OUT" "archived previous note: .*/archive/feat\+x--"
n=$(find "$CLAUDE_HANDOFF_DIR/$SLUG/archive" -type f | wc -l | tr -d ' ')
if [ "$n" = 1 ]; then ok "one archive entry"; else no "one archive entry (got $n)"; fi
check "current note is the newest" "$(cat "$f")" "^goal: second goal$"
OUT=$(cd "$REPO" && printf '' | "$SH" "$H" save 2>&1)
check "empty save is refused" "$OUT" "not saved"
OUT=$(cd "$REPO" && printf 'no goal here\n' | "$SH" "$H" save 2>&1)
check "save without goal is refused" "$OUT" "must start with a 'goal:"
OUT=$(cd "$REPO" && printf 'goal: x\n\n  \n' | "$SH" "$H" save 2>&1)
check "whitespace-only body is refused" "$OUT" "body is empty"
check "refused saves leave the note" "$(cat "$f")" "^goal: second goal$"
OUT=$(cd "$REPO" && printf -- '---\ngoal: fm goal\nbranch: fake\n---\n## Done\n- y\n' | "$SH" "$H" save 2>&1)
check "frontmatter-form input is accepted" "$(cat "$f")" "^goal: fm goal$"
check_not "caller frontmatter cannot override branch" "$(cat "$f")" "^branch: fake$"

echo "# draft"
run "$REPO" state
check "state names the draft in the git dir" "$OUT" "draft path: $REPO/\.git/handoff-draft\.md$"
run "$WT2" state
check "worktree draft is per worktree" "$OUT" "draft path: $REPO/\.git/worktrees/wt2/handoff-draft\.md$"
run "$REPO" save --draft
check "save --draft without a draft is refused" "$OUT" "no draft at"
printf 'no goal\n' >"$REPO/.git/handoff-draft.md"
run "$REPO" save --draft
check "bad draft is refused" "$OUT" "not saved"
if [ -f "$REPO/.git/handoff-draft.md" ]; then ok "refused draft is kept for fixing"; else no "refused draft is kept for fixing"; fi
note "draft goal" >"$REPO/.git/handoff-draft.md"
# shellcheck disable=SC2016 # literal backticks and $() on purpose
printf '`git switch x && ./run.sh` $(nope)\n' >>"$REPO/.git/handoff-draft.md"
run "$REPO" save --draft
check "save --draft writes the note" "$OUT" "saved: .*/feat\+x\.md"
# shellcheck disable=SC2016 # literal backticks and $() on purpose
check "draft text is stored verbatim" "$(cat "$f")" '^`git switch x && ./run.sh` \$\(nope\)$'
if [ ! -e "$REPO/.git/handoff-draft.md" ]; then ok "draft removed after save"; else no "draft removed after save"; fi
check_not "draft is not visible to git" "$(git -C "$REPO" status --short)" "handoff-draft"

echo "# drift"
run "$REPO" pickup
check "pickup shows the note" "$OUT" "## Done"
check_not "pickup hides the status snapshot" "$OUT" "handoff:status"
check "no new commits yet" "$OUT" "commits: none since"
check "uncommitted unchanged" "$OUT" "uncommitted: unchanged"
(cd "$REPO" && echo b >b && git add b && git commit -qm second)
run "$REPO" pickup status
check "new commit is reported" "$OUT" "NEW-COMMITS: 1"
check "new commit subject listed" "$OUT" "second$"
(cd "$REPO" && echo dirty >>a)
run "$REPO" pickup
check "dirty tree is reported" "$OUT" "UNCOMMITTED-CHANGED"
(cd "$REPO" && git checkout -q -- a)
save "$REPO" "before amend"
(cd "$REPO" && git commit -q --amend -m second-amended)
run "$REPO" pickup
check "amended head is REWRITTEN" "$OUT" "REWRITTEN"

echo "# pickup arguments"
run "$WT2" pickup
check "no note for other branch lists notes" "$OUT" "No handoff note for this branch"
check "list shows feat/x" "$OUT" "- feat/x \(.* old\): before amend"
run "$WT2" pickup feat/x
check "pickup <branch> from another worktree" "$OUT" "goal: before amend"
check "other-branch drift flagged" "$OUT" "OTHER-BRANCH"
run "$WT2" pickup 'bad..name'
check "invalid branch is rejected" "$OUT" "not a valid branch name"
run "$WT2" pickup nosuch
check "missing branch note falls back to list" "$OUT" "No handoff note for branch 'nosuch'"
run "$REPO" pickup list
check "pickup list" "$OUT" "Handoff notes for $REPO"
check "list shows archive count" "$OUT" "archived: [0-9]+"
save "$WT2" "wt2 goal"
git -C "$WT2" checkout -q -b renamed 2>/dev/null
git -C "$WT2" branch -q -D other
run "$WT2" pickup other
check "deleted branch flagged" "$OUT" "BRANCH-GONE"

echo "# edge repos"
git -C "$REPO" checkout -q --detach
run "$REPO" state
check "detached HEAD slug" "$OUT" "note path: .*/detached-[0-9a-f]+\.md$"
save "$REPO" "detached goal"
check "detached save works" "$OUT" "saved: .*/detached-"
git -C "$REPO" checkout -q 'feat/x'
UNBORN="$WORK/unborn"
git init -q -b fresh "$UNBORN"
run "$UNBORN" state
check "unborn HEAD" "$OUT" "head: none"
save "$UNBORN" "unborn goal"
check "unborn save works" "$OUT" "saved: .*/fresh\.md"
run "$UNBORN" pickup
check "unborn pickup works" "$OUT" "goal: unborn goal"
PLAIN="$WORK/plain"
mkdir -p "$PLAIN"
run "$PLAIN" state
check "non-git slug" "$OUT" "note path: .*/_nogit\.md$"
check "non-git draft in cwd" "$OUT" "draft path: $PLAIN/\.handoff-draft\.md$"
save "$PLAIN" "plain goal"
run "$PLAIN" pickup
check "non-git pickup works" "$OUT" "goal: plain goal"
run "$PLAIN" bogus
check "unknown subcommand prints usage" "$OUT" "usage:"

echo "# hint"
run "$REPO" hint
if printf '%s' "$OUT" | jq -e '.systemMessage and .hookSpecificOutput.additionalContext and .hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1; then
	ok "hint is valid JSON with both fields"
else
	no "hint is valid JSON with both fields" "$OUT"
fi
git -C "$REPO" checkout -q -b 'quote"branch' 2>/dev/null
save "$REPO" 'goal with "quotes" and \ backslash'
run "$REPO" hint
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then ok "hint escapes quotes and backslashes"; else no "hint escapes quotes and backslashes" "$OUT"; fi
git -C "$REPO" checkout -q 'feat/x'
run "$WT2" hint
if [ -z "$OUT" ]; then ok "hint is silent without a note"; else no "hint is silent without a note" "$OUT"; fi
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
i=0
while [ $i -lt 10 ]; do (cd "$REPO" && "$SH" "$H" hint >/dev/null); i=$((i + 1)); done
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
avg=$(((end - start) / 10))
if [ "$avg" -lt 500 ]; then ok "hint averages ${avg}ms (<500ms; hook timeout is 5s)"; else no "hint averages ${avg}ms (<500ms; hook timeout is 5s)"; fi

echo "# clear"
run "$REPO" clear
check "clear archives the note" "$OUT" "archived: .*/archive/feat\+x--"
run "$REPO" hint
if [ -z "$OUT" ]; then ok "hint silent after clear"; else no "hint silent after clear" "$OUT"; fi
run "$REPO" clear
check "clear with no note" "$OUT" "nothing to clear"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

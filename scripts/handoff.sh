#!/bin/sh
# handoff.sh - storage, repo state and drift logic for the handoff plugin.
#
# Usage: handoff.sh state | save [--draft] | pickup [status|list|<branch>] | list | clear | hint
#
# Notes live outside the repo, one per (main repository, branch):
#   ${CLAUDE_HANDOFF_DIR:-~/.claude/handoffs}/<repo-slug>/<branch-slug>.md
# Every subcommand exits 0 so a skill's `!` injection never aborts; problems
# are printed as "handoff: ..." lines instead.

ROOT=${CLAUDE_HANDOFF_DIR:-$HOME/.claude/handoffs}
STATUS_MAX=40
LOG_MAX=20
STALE_DAYS=7

say() { printf 'handoff: %s\n' "$*"; }

in_git() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# Sets MAIN, WORKTREE, BRANCH, HEAD_SHA, BRANCH_SLUG, DIR, NOTE for the cwd.
resolve() {
	if in_git; then
		# The common dir is shared by every worktree, so all of them map to one repo slug.
		common=$(git rev-parse --git-common-dir 2>/dev/null)
		MAIN=$(cd "$common/.." 2>/dev/null && pwd -P)
		WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null)
		BRANCH=$(git symbolic-ref --short -q HEAD 2>/dev/null)
		HEAD_SHA=$(git rev-parse --short HEAD 2>/dev/null) || HEAD_SHA=none
		[ -n "$HEAD_SHA" ] || HEAD_SHA=none
		if [ -n "$BRANCH" ]; then
			BRANCH_SLUG=$(branch_slug "$BRANCH")
		else
			BRANCH_SLUG="detached-$HEAD_SHA"
		fi
	else
		MAIN=$(pwd -P)
		WORKTREE=$MAIN
		BRANCH=
		HEAD_SHA=none
		BRANCH_SLUG=_nogit
	fi
	DIR="$ROOT/$(printf '%s' "$MAIN" | sed 's#/#-#g')"
	NOTE="$DIR/$BRANCH_SLUG.md"
	# Where the skill writes the note before `save --draft` moves it into place. Inside the
	# (per-worktree) git dir it is never committed; the note text never passes through a shell.
	if in_git; then
		DRAFT="$(git rev-parse --absolute-git-dir 2>/dev/null)/handoff-draft.md"
	else
		DRAFT="$MAIN/.handoff-draft.md"
	fi
}

branch_slug() { printf '%s' "$1" | sed 's#/#+#g'; }

# fm KEY FILE - value of KEY from the file's leading frontmatter block.
fm() {
	awk -v k="$1" '
		NR == 1 { if ($0 != "---") exit; next }
		$0 == "---" { exit }
		index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }
	' "$2"
}

# age FILE - "12m", "5h" or "3d" since the note's created_epoch.
age() {
	e=$(fm created_epoch "$1")
	case $e in '' | *[!0-9]*) printf 'unknown age'; return ;; esac
	s=$(($(date +%s) - e))
	if [ "$s" -lt 3600 ]; then
		printf '%sm old' $((s / 60))
	elif [ "$s" -lt 86400 ]; then
		printf '%sh old' $((s / 3600))
	else
		printf '%sd old' $((s / 86400))
	fi
}

age_days() {
	e=$(fm created_epoch "$1")
	case $e in '' | *[!0-9]*) echo 0; return ;; esac
	echo $((($(date +%s) - e) / 86400))
}

git_status() { git status --short 2>/dev/null; }

# The status snapshot `save` appends, used later to detect uncommitted drift.
recorded_status() {
	awk '/^<!-- handoff:status$/ { on = 1; next } on && /^-->$/ { exit } on' "$1"
}

print_note() {
	awk '/^<!-- handoff:status$/ { skip = 1 } !skip { print } skip && /^-->$/ { skip = 0 }' "$1"
}

archive() {
	mkdir -p "$DIR/archive" || return 1
	dest="$DIR/archive/$BRANCH_SLUG--$(date +%Y%m%d-%H%M%S).md"
	[ -e "$dest" ] && dest="${dest%.md}-$$.md"
	mv "$1" "$dest" && printf '%s\n' "$dest"
}

cmd_state() {
	resolve
	echo "repo: $MAIN"
	echo "worktree: $WORKTREE"
	if in_git; then
		echo "branch: ${BRANCH:-(detached HEAD)}"
		if [ "$HEAD_SHA" = none ]; then
			echo "head: none (no commits yet)"
		else
			echo "head: $HEAD_SHA $(git log -1 --format=%s 2>/dev/null)"
		fi
		up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
		if [ -n "$up" ]; then
			counts=$(git rev-list --left-right --count "$up...HEAD" 2>/dev/null)
			behind=${counts%%[[:space:]]*}
			ahead=${counts##*[[:space:]]}
			echo "upstream: $up (behind ${behind:-?}, ahead ${ahead:-?})"
		else
			echo "upstream: none"
		fi
		st=$(git_status)
		n=$(printf '%s' "$st" | grep -c '^' )
		echo
		echo "## git status --short ($n entries)"
		[ -n "$st" ] && printf '%s\n' "$st" | head -n "$STATUS_MAX"
		[ "$n" -gt "$STATUS_MAX" ] && echo "... $((n - STATUS_MAX)) more"
		echo
		echo "## diff against HEAD"
		git diff --stat HEAD 2>/dev/null | tail -n 1
		echo
		echo "## recent commits"
		git log --oneline -10 2>/dev/null
	else
		echo "branch: (not a git repository)"
	fi
	echo
	echo "note path: $NOTE"
	echo "draft path: $DRAFT"
	if [ -f "$NOTE" ]; then
		echo "existing note: yes ($(age "$NOTE")); saving archives it first"
	else
		echo "existing note: no"
	fi
}

# save [--draft] - note text from the draft file, or from stdin.
cmd_save() {
	resolve
	tmp=$(mktemp "${TMPDIR:-/tmp}/handoff.XXXXXX") || { say "cannot create a temp file"; return; }
	if [ "$1" = --draft ]; then
		if [ ! -s "$DRAFT" ]; then
			rm -f "$tmp"
			say "not saved: no draft at $DRAFT"
			return
		fi
		cat "$DRAFT" >"$tmp"
	else
		cat >"$tmp"
	fi
	first=$(head -n 1 "$tmp" | tr -d '\r')
	if [ "$first" = "---" ]; then
		goal=$(fm goal "$tmp")
		body=$(awk 'NR > 1 && $0 == "---" { on = 1; next } on && NR > 1' "$tmp")
	else
		case $first in
		goal:*)
			goal=${first#goal:}
			body=$(tail -n +2 "$tmp")
			;;
		*)
			rm -f "$tmp"
			say "not saved: the note must start with a 'goal: <one line>' line"
			return
			;;
		esac
	fi
	rm -f "$tmp"
	goal=$(printf '%s' "$goal" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	if [ -z "$goal" ]; then
		say "not saved: the goal line is empty"
		return
	fi
	if ! printf '%s' "$body" | grep -q '[^[:space:]]'; then
		say "not saved: the note body is empty"
		return
	fi
	mkdir -p "$DIR" || { say "cannot create $DIR"; return; }
	out=$(mktemp "$DIR/.tmp.XXXXXX") || { say "cannot write in $DIR"; return; }
	{
		echo "---"
		echo "repo: $MAIN"
		echo "worktree: $WORKTREE"
		echo "branch: $BRANCH"
		echo "head: $HEAD_SHA"
		echo "created: $(date +%Y-%m-%dT%H:%M:%S%z)"
		echo "created_epoch: $(date +%s)"
		echo "goal: $goal"
		echo "---"
		printf '%s\n' "$body"
		echo
		echo "<!-- handoff:status"
		in_git && git_status
		echo "-->"
	} >"$out"
	if [ -f "$NOTE" ]; then
		prev=$(archive "$NOTE") && echo "archived previous note: $prev"
	fi
	if mv "$out" "$NOTE"; then
		echo "saved: $NOTE"
		[ "$1" = --draft ] && rm -f "$DRAFT"
	else
		rm -f "$out"
		say "could not move the note into place"
	fi
}

# drift NOTE - compare the note's recorded state with the repository now.
drift() {
	note=$1
	echo
	echo "## Drift since handoff (computed by handoff.sh)"
	echo "age: $(age "$note")"
	d=$(age_days "$note")
	[ "$d" -gt "$STALE_DAYS" ] && echo "STALE: written $d days ago"
	in_git || return 0

	nbranch=$(fm branch "$note")
	nhead=$(fm head "$note")
	nworktree=$(fm worktree "$note")
	same=yes
	target=HEAD
	if [ -n "$nbranch" ] && [ "$nbranch" != "$BRANCH" ]; then
		same=no
		echo "OTHER-BRANCH: note is for '$nbranch'; you are on '${BRANCH:-detached HEAD}'"
		if git rev-parse --verify -q "refs/heads/$nbranch" >/dev/null; then
			target="refs/heads/$nbranch"
		else
			echo "BRANCH-GONE: '$nbranch' no longer exists locally"
			target=
		fi
	fi
	if [ "$same" = yes ] && [ -n "$nworktree" ] && [ "$nworktree" != "$WORKTREE" ]; then
		echo "WORKTREE-MOVED: note written in $nworktree; now in $WORKTREE"
	fi

	if [ -n "$target" ] && [ -n "$nhead" ] && [ "$nhead" != none ]; then
		if ! git cat-file -e "$nhead^{commit}" 2>/dev/null; then
			echo "REWRITTEN: recorded head $nhead no longer exists"
		elif ! git merge-base --is-ancestor "$nhead" "$target" 2>/dev/null; then
			echo "REWRITTEN: recorded head $nhead is not an ancestor of $target (rebase, reset or amend)"
		else
			n=$(git rev-list --count "$nhead..$target" 2>/dev/null)
			if [ "${n:-0}" -gt 0 ]; then
				echo "NEW-COMMITS: $n since $nhead"
				git log --oneline "$nhead..$target" 2>/dev/null | head -n "$LOG_MAX"
			else
				echo "commits: none since $nhead"
			fi
		fi
	fi

	[ "$same" = yes ] || return 0
	now=$(git_status)
	was=$(recorded_status "$note")
	if [ "$now" = "$was" ]; then
		echo "uncommitted: unchanged since handoff"
	else
		echo "UNCOMMITTED-CHANGED: working tree differs from the handoff snapshot; now:"
		if [ -n "$now" ]; then
			printf '%s\n' "$now" | head -n "$STATUS_MAX"
		else
			echo "(clean)"
		fi
	fi
}

show() {
	echo "note: $1"
	echo
	print_note "$1"
	drift "$1"
}

cmd_pickup() {
	resolve
	case $1 in
	'' | status)
		if [ -f "$NOTE" ]; then
			show "$NOTE"
		else
			echo "No handoff note for this branch ($BRANCH_SLUG)."
			cmd_list
		fi
		;;
	list) cmd_list ;;
	*)
		if ! git check-ref-format --branch "$1" >/dev/null 2>&1; then
			say "not a valid branch name: $1"
			cmd_list
			return
		fi
		f="$DIR/$(branch_slug "$1").md"
		if [ -f "$f" ]; then
			show "$f"
		else
			echo "No handoff note for branch '$1'."
			cmd_list
		fi
		;;
	esac
}

cmd_list() {
	resolve
	echo "Handoff notes for $MAIN:"
	found=
	for f in "$DIR"/*.md; do
		[ -f "$f" ] || continue
		found=1
		b=$(fm branch "$f")
		[ -n "$b" ] || b=$(basename "$f" .md)
		printf -- '- %s (%s): %s\n' "$b" "$(age "$f")" "$(fm goal "$f")"
	done
	[ -n "$found" ] || echo "(none)"
	if [ -d "$DIR/archive" ]; then
		n=$(find "$DIR/archive" -type f -name '*.md' | wc -l | tr -d ' ')
		echo "archived: $n in $DIR/archive"
	fi
}

cmd_clear() {
	resolve
	if [ -f "$NOTE" ]; then
		dest=$(archive "$NOTE") && echo "archived: $dest"
	else
		echo "No handoff note for this branch ($BRANCH_SLUG); nothing to clear."
	fi
}

json_escape() {
	printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# SessionStart hook: one line when a note exists for this branch, nothing otherwise.
cmd_hint() {
	resolve
	[ -f "$NOTE" ] || return 0
	msg="Handoff note for ${BRANCH:-$BRANCH_SLUG} ($(age "$NOTE")): $(fm goal "$NOTE"). Run /handoff:pickup to load it."
	m=$(json_escape "$msg")
	printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$m" "$m"
}

case $1 in
state) cmd_state ;;
save) cmd_save "$2" ;;
pickup) cmd_pickup "$2" ;;
list) cmd_list ;;
clear) cmd_clear ;;
hint) cmd_hint ;;
*) say "usage: handoff.sh state | save [--draft] | pickup [status|list|<branch>] | list | clear | hint" ;;
esac
exit 0

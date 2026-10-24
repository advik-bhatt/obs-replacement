#!/bin/sh
# merge-desk sync-push, v1.0.0
# The one sanctioned way for a Claude thread to push work to a shared repo.
#
# Master copy:   knowledge-base/global/merge-desk/sync-push.sh
# Vendored copy: <repo>/.claude/merge-desk/sync-push.sh  (same content, so a
#                thread that only cloned one repo still has the protocol)
#
# What it does, in order:
#   1. refuses a dirty tree (commit first; untracked files are fine)
#   2. turns on git rerere, and the mergiraf structural merge driver when the
#      binary is installed, so trivial conflicts resolve themselves
#   3. fetch, rebase onto origin/main, push. Retries the race against other
#      threads up to 5 times with backoff.
#   4. on a real content conflict: captures both sides' commits and the
#      conflicted hunks, writes a conflict-card skeleton, aborts the rebase
#      (tree left exactly as before), and exits 42 so the thread follows the
#      merge-desk skill: resolve intent-first, re-push, file the card.
#
# Exit codes:
#   0  pushed, or nothing to push
#   3  dirty tree, commit first
#   4  push kept failing (network or persistent rejection)
#   5  target branch refused by this environment; work pushed to the current
#      side branch instead, fold-to-main card owed
#   42 conflict captured, card skeleton written, thread must resolve
set -u

TARGET="${MERGE_DESK_BRANCH:-main}"
REMOTE="${MERGE_DESK_REMOTE:-origin}"
MAX_TRIES=5

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "merge-desk: not inside a git repo" >&2; exit 3; }
cd "$REPO_ROOT" || exit 3
REPO_NAME=$(basename "$REPO_ROOT")
DESK_DIR="$REPO_ROOT/.claude/merge-desk"
mkdir -p "$DESK_DIR"
SESSION="${CLAUDE_SESSION_ID:-$(hostname 2>/dev/null || echo host)-$$}"
NOW() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- 0. never commit the runtime scratch files this script writes ---------
if [ -d .git ] || [ -f .git ]; then
  GITDIR=$(git rev-parse --git-dir)
  mkdir -p "$GITDIR/info"
  grep -qs 'merge-desk/last-conflict' "$GITDIR/info/exclude" 2>/dev/null || {
    echo ".claude/merge-desk/last-conflict.*" >> "$GITDIR/info/exclude"
  }
fi

# --- 1. clean tree check --------------------------------------------------
DIRTY=$(git status --porcelain 2>/dev/null | grep -v '^??' || true)
if [ -n "$DIRTY" ]; then
  echo "merge-desk: uncommitted changes. Commit them first, then re-run:" >&2
  printf '%s\n' "$DIRTY" | head -10 >&2
  exit 3
fi

# --- 2. cheap conflict-shrinkers -----------------------------------------
git config rerere.enabled true 2>/dev/null || true
if command -v mergiraf >/dev/null 2>&1; then
  git config merge.mergiraf.name "mergiraf structural merge" 2>/dev/null || true
  git config merge.mergiraf.driver \
    "mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L" 2>/dev/null || true
  GITDIR=$(git rev-parse --git-dir)
  if ! grep -qs 'merge=mergiraf' "$GITDIR/info/attributes" 2>/dev/null; then
    mergiraf languages --gitattributes >> "$GITDIR/info/attributes" 2>/dev/null || true
  fi
fi

# --- ledger: best-effort, never fatal ------------------------------------
ledger() {
  _event="$1"; _extra="${2:-}"
  for d in "${SECOND_BRAIN_KB:-}" "$REPO_ROOT/../knowledge-base" \
           "$HOME/knowledge-base" "$HOME/code/knowledge-base"; do
    if [ -n "$d" ] && [ -d "$d/projects" ]; then
      mkdir -p "$d/projects/merge-desk" 2>/dev/null || return 0
      printf '{"ts":"%s","repo":"%s","session":"%s","event":"%s"%s}\n' \
        "$(NOW)" "$REPO_NAME" "$SESSION" "$_event" "$_extra" \
        >> "$d/projects/merge-desk/ledger.jsonl" 2>/dev/null || true
      return 0
    fi
  done
  return 0
}

# Ledger lines are written AFTER the push they describe, so they can never ride
# along with it. Left alone, every successful push leaves the knowledge-base
# permanently one line dirty. Sweep it: commit the ledger and push it on its own,
# best-effort — if this races another thread, the line simply rides along with
# the next commit, which is the old behavior and harmless.
ledger_sweep() {
  for d in "${SECOND_BRAIN_KB:-}" "$REPO_ROOT/../knowledge-base" \
           "$HOME/knowledge-base" "$HOME/code/knowledge-base"; do
    [ -n "$d" ] && [ -d "$d/.git" ] || continue
    git -C "$d" diff --quiet -- projects/merge-desk/ledger.jsonl 2>/dev/null && return 0
    # only ever touch the ledger; never sweep up someone else's work in progress
    git -C "$d" add projects/merge-desk/ledger.jsonl 2>/dev/null || return 0
    git -C "$d" -c core.hooksPath=.githooks commit -q \
      -m "merge-desk: log ledger sync push" \
      -- projects/merge-desk/ledger.jsonl 2>/dev/null || return 0
    git -C "$d" push -q origin HEAD:refs/heads/main 2>/dev/null || true
    return 0
  done
  return 0
}

# --- 3. fetch / rebase / push loop ---------------------------------------
TRY=1
while [ "$TRY" -le "$MAX_TRIES" ]; do
  if ! git fetch "$REMOTE" "$TARGET" 2>/dev/null; then
    echo "merge-desk: fetch failed (try $TRY/$MAX_TRIES), backing off" >&2
    sleep $((TRY * 2)); TRY=$((TRY + 1)); continue
  fi

  AHEAD=$(git rev-list --count "$REMOTE/$TARGET..HEAD" 2>/dev/null || echo 0)
  BEHIND=$(git rev-list --count "HEAD..$REMOTE/$TARGET" 2>/dev/null || echo 0)

  if [ "$AHEAD" -eq 0 ]; then
    if [ "$BEHIND" -gt 0 ]; then
      # nothing of ours to push; still bring the thread up to date
      git rebase "$REMOTE/$TARGET" >/dev/null 2>&1 || git rebase --abort 2>/dev/null || true
    fi
    echo "merge-desk: nothing to push ($TARGET already has everything)."
    exit 0
  fi

  if [ "$BEHIND" -gt 0 ]; then
    # another thread landed work since we branched off: replay ours on top
    BASE=$(git merge-base HEAD "$REMOTE/$TARGET")
    OURS_LOG=$(git log --format='%h %s' "$BASE..HEAD")
    THEIRS_LOG=$(git log --format='%h %s' "$BASE..$REMOTE/$TARGET")
    PRE_REBASE_HEAD=$(git rev-parse HEAD)
    if ! git -c rerere.enabled=true rebase "$REMOTE/$TARGET" >/dev/null 2>&1; then
      # ----- real conflict: capture, abort, hand off to the thread --------
      CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
      HUNKS=$(git diff --diff-filter=U 2>/dev/null | head -300 || true)
      git rebase --abort 2>/dev/null || true

      CARD="$DESK_DIR/last-conflict.md"
      META="$DESK_DIR/last-conflict.json"
      {
        echo "# Conflict card skeleton (repo: $REPO_NAME)"
        echo
        echo "Captured $(NOW) by session $SESSION. Fill the plain-English"
        echo "sections per the merge-desk skill, then post as a GitHub issue"
        echo "titled: [merge-desk] $REPO_NAME: <6-10 word plain summary>"
        echo
        echo "## This thread was doing (from its commits)"
        printf '%s\n' "$OURS_LOG"
        echo
        echo "## The other thread landed (already on $TARGET)"
        printf '%s\n' "$THEIRS_LOG"
        echo
        echo "## Files where they collided"
        printf '%s\n' "$CONFLICT_FILES"
        echo
        echo "## Raw conflicted hunks (first 300 lines)"
        echo '```diff'
        printf '%s\n' "$HUNKS"
        echo '```'
      } > "$CARD"
      {
        printf '{"mdv":1,"repo":"%s","session":"%s","ts":"%s",' \
          "$REPO_NAME" "$SESSION" "$(NOW)"
        printf '"base":"%s","ours":"%s","theirs":"%s",' \
          "$BASE" "$PRE_REBASE_HEAD" "$(git rev-parse "$REMOTE/$TARGET")"
        printf '"files":['
        FIRST=1
        for f in $CONFLICT_FILES; do
          [ "$FIRST" -eq 1 ] && FIRST=0 || printf ','
          printf '"%s"' "$f"
        done
        printf ']}\n'
      } > "$META"
      ledger conflict ",\"files\":\"$(printf '%s' "$CONFLICT_FILES" | tr '\n' ' ')\""

      cat <<EOF
MERGE-DESK CONFLICT: two threads changed the same code in $REPO_NAME.
The rebase was aborted; your work is intact and unpushed.

Protocol for you (the Claude thread) - follow the merge-desk skill:
 1. Read $CARD and $META.
 2. Re-run: git rebase $REMOTE/$TARGET
    Resolve each file INTENT-FIRST: read both sides' commit messages and
    surrounding code, keep BOTH intents when possible. Never blind-pick
    ours/theirs. Then: git add <files> && git rebase --continue
 3. If .claude/merge-desk/strict-paths exists and matches any conflicted
    file: DO NOT push. Post the card as 'awaiting-approval' and stop.
 4. Otherwise re-run this script to push, then post the conflict card as a
    GitHub issue (title prefix [merge-desk], mode: auto-resolved) so the
    founder can review, reply, or revert. Use the card template in the
    merge-desk skill.
EOF
      exit 42
    fi
  fi

  # tree is now ahead-only: push, racing other threads
  PUSH_ERR=$(git push "$REMOTE" "HEAD:refs/heads/$TARGET" 2>&1)
  PUSH_RC=$?
  if [ "$PUSH_RC" -eq 0 ]; then
    echo "merge-desk: pushed to $TARGET (try $TRY, $AHEAD commit(s))."
    ledger push_ok ",\"tries\":$TRY,\"commits\":$AHEAD"
    ledger_sweep
    exit 0
  fi
  case "$PUSH_ERR" in
    *fetch\ first*|*non-fast-forward*|*"Updates were rejected"*)
      echo "merge-desk: lost the push race (try $TRY/$MAX_TRIES), rebasing again" >&2
      sleep $(( (TRY * 2) + ($$ % 3) ))
      TRY=$((TRY + 1)); continue ;;
    *protected*|*denied*|*not\ allowed*|*restricted*|*policy*|*working\ branch*)
      CUR=$(git rev-parse --abbrev-ref HEAD)
      if [ "$CUR" != "$TARGET" ] && [ "$CUR" != "HEAD" ]; then
        if git push -u "$REMOTE" "$CUR" >/dev/null 2>&1; then
          ledger side_branch ",\"branch\":\"$CUR\""
          cat <<EOF
merge-desk: this environment refuses direct pushes to $TARGET.
Work is safe on branch '$CUR'. You (the thread) must now file a
fold-to-main card: a GitHub issue titled
  [merge-desk] $REPO_NAME: fold $CUR into $TARGET
listing what the branch contains, so a local session or the steward can
land it on $TARGET. Advik's standing rule is main-only; this is the
sanctioned exception when the environment physically blocks main.
EOF
          exit 5
        fi
      fi
      printf '%s\n' "$PUSH_ERR" >&2; exit 4 ;;
    *)
      echo "merge-desk: push failed (try $TRY/$MAX_TRIES): $PUSH_ERR" >&2
      sleep $((TRY * 2)); TRY=$((TRY + 1)); continue ;;
  esac
done

echo "merge-desk: gave up after $MAX_TRIES tries. Nothing was lost; your commits are local. Re-run later." >&2
ledger push_exhausted ""
exit 4

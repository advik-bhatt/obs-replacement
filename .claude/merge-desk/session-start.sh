#!/bin/sh
# merge-desk session-start, v1.0.0 (SessionStart hook)
# Cheap cross-thread situational awareness, printed into the new session's
# context. Never blocks, never fails, tolerates being offline.
set -u

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
TARGET="${MERGE_DESK_BRANCH:-main}"

if command -v timeout >/dev/null 2>&1; then
  timeout 8 git fetch origin "$TARGET" >/dev/null 2>&1 || true
else
  git fetch origin "$TARGET" >/dev/null 2>&1 || true
fi

BEHIND=$(git rev-list --count "HEAD..origin/$TARGET" 2>/dev/null || echo 0)
AHEAD=$(git rev-list --count "origin/$TARGET..HEAD" 2>/dev/null || echo 0)
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo repo)

echo "## Merge desk ($REPO)"
if [ "$BEHIND" -gt 0 ]; then
  echo "Other threads landed $BEHIND commit(s) on $TARGET since this clone. Rebase before big edits: git rebase origin/$TARGET"
else
  echo "This clone is current with origin/$TARGET."
fi
[ "$AHEAD" -gt 0 ] && echo "This clone carries $AHEAD unpushed commit(s)."
echo "Rules: push ONLY via sync-push (.claude/merge-desk/sync-push.sh; in knowledge-base: global/merge-desk/sync-push.sh). Before substantive work, check GitHub issues titled '[merge-desk]' on this repo (GitHub MCP or gh): apply any APPROVED conflict cards first, and announce your goal as a comment on the '[merge-desk] Thread board' issue so other threads see you."
exit 0

#!/bin/sh
# merge-desk guard, v1.0.0 (PreToolUse hook, matcher: Bash)
# Intercepts raw `git push` from any thread and routes it through sync-push,
# which rebases, retries the race, and files a conflict card when threads
# collide. Exit 2 blocks the tool call; stderr is what the thread reads.
#
# Escape hatch (rare, deliberate): prefix the command with MERGE_DESK_BYPASS=1
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -z "$PAYLOAD" ] && exit 0

CMD=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || true)
[ -z "$CMD" ] && exit 0

case "$CMD" in
  *MERGE_DESK_BYPASS=1*) exit 0 ;;
  *sync-push.sh*)        exit 0 ;;
esac

case "$CMD" in
  *git\ push*--dry-run*|*git\ push*-n\ *) exit 0 ;;
  *git\ push*)
    cat >&2 <<'EOF'
merge-desk: raw `git push` is intercepted on this repo because parallel
threads share one branch. Push through the protocol instead:

  sh .claude/merge-desk/sync-push.sh

(in the knowledge-base repo: sh global/merge-desk/sync-push.sh)

It fetches, rebases onto origin/main, retries the race against other
threads, and if your work truly collides with another thread's it writes a
conflict card and walks you through an intent-first resolution. If you are
certain a raw push is right, prefix with MERGE_DESK_BYPASS=1.
EOF
    exit 2 ;;
esac
exit 0

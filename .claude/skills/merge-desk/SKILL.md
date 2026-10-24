---
name: merge-desk
description: The multi-thread merge protocol for all advik-bhatt repos. Use whenever you are about to push work, whenever sync-push exits 42 (conflict card written) or 5 (side-branch fallback), whenever a rebase or merge hits conflict markers, whenever the user mentions threads colliding, merge conflicts, or approving a resolution, and at session start on a shared repo to apply approved conflict cards. Covers pushing discipline, intent-first conflict resolution, plain-English conflict cards as GitHub issues, the founder approval loop, and the merge-desk ledger.
---

# Merge desk: how parallel Claude threads share one branch

Advik runs several Claude threads at once on the same repos. All work lands
directly on `main` (his hard rule, no worktrees, no feature branches). This
protocol is how threads avoid, resolve, and report the collisions that
causes. The point of every step: he should learn about a collision in plain
English, on his phone, with an approve/change/revert lever, and the raw data
stays his.

## 1. Pushing (always)

Never run raw `git push`. Push through the protocol script:

- vendored per repo: `sh .claude/merge-desk/sync-push.sh`
- in knowledge-base: `sh global/merge-desk/sync-push.sh`

It fetches, rebases onto `origin/main`, retries push races with backoff, and
exits `0` (done), `3` (commit first), `42` (real conflict, card skeleton
written), or `5` (environment refused main; work parked on a side branch,
fold-to-main card owed). Push early and often: small, frequent syncs shrink
the collision window more than anything else.

## 2. When sync-push exits 42 (a real conflict)

Your work and another thread's work changed the same code. The script
already aborted the rebase (nothing is lost) and wrote:

- `.claude/merge-desk/last-conflict.md` (both sides' commits, files, hunks)
- `.claude/merge-desk/last-conflict.json` (machine metadata)

Do this, in order:

1. **Understand both intents first.** Read the card skeleton: your commits
   are "this thread", the landed commits are "the other thread". Read the
   surrounding code. Only then rerun `git rebase origin/main` and resolve
   each hunk to preserve BOTH intents. Never blind-pick ours/theirs; if the
   two intents are truly incompatible, prefer the intent already landed on
   main unless yours clearly supersedes it, and say which you chose and why
   in the card.
2. **Check strict paths.** If `.claude/merge-desk/strict-paths` exists and
   any conflicted file matches a line in it (glob per line), do NOT push.
   Post the card (step 4) with `mode: awaiting-approval`, tell the user in
   your reply, and stop. Advik approves on the issue; the next thread (or
   the steward) applies it.
3. **Verify, then push.** Run the repo's quick check if one exists
   (`npm run build`, tests, etc. — whatever the repo's CLAUDE.md says).
   Re-run sync-push.
4. **File the conflict card** so Advik can review from his phone. Create a
   GitHub issue on the repo (GitHub MCP `issue_write`; fallbacks: `gh` CLI,
   then commit the filled card to `merge-desk/cards/<ts>.md` in the repo and
   push). Title: `[merge-desk] <repo>: <6-10 word plain summary>`. Body: use
   the template below. Plain English throughout: he reads these
   non-technically. No em dashes.
5. **Ledger.** Append what happened to
   `knowledge-base/projects/merge-desk/ledger.jsonl` (event:
   `resolved_auto` or `awaiting_approval`, plus `files`). If knowledge-base
   is not on disk, the issue itself is the record; skip silently.

## 3. The card template

```markdown
## What happened
Two threads worked on <repo> at the same time and both changed <area>.
This card is the resolution record. Nothing is broken; main works.

## The two sides
**Thread A (this thread) wanted:** <one sentence, from its commits>
**Thread B (already landed) wanted:** <one sentence, from its commits>

## Where they collided
- `<file>`: <one plain sentence per file on what each side changed>

## What I did
<2-4 sentences: the resolution, which intents were kept, why. If
awaiting-approval: what I propose instead, and that nothing was pushed.>

## Your move
- **Fine as is:** react 👍 or reply "approve" (or ignore it; silence keeps it).
- **Change it:** reply with instructions; the next thread on this repo (or
  the daily steward) applies them.
- **Undo it entirely:** reply "revert".

<details><summary>Technical detail</summary>

<the conflicted hunks and resolution diff, from last-conflict.md>

```json
{"mdv":1,"repo":"<repo>","mode":"auto-resolved|awaiting-approval","base":"<sha>","ours":"<sha>","theirs":"<sha>","resolved":"<sha>","files":["..."],"session":"<id>"}
```
</details>
```

## 4. Session start duties (shared repos)

- Read the merge-desk context the SessionStart hook printed (behind/ahead).
- Before substantive work: list open issues titled `[merge-desk]` on the
  repo. If any card has an approval or founder instructions that are not yet
  applied, apply them FIRST (they are his decisions, they outrank new work),
  comment on the issue with what you did, close it.
- Announce yourself: one comment on the repo's `[merge-desk] Thread board`
  issue: `thread <short-id> started: <one-line goal>`. Skip for trivial or
  read-only sessions. When your goal changes materially, comment again.
  This is how other threads and the live board see you.
- If another thread announced recently (24h) and its goal overlaps yours,
  steer around its files or coordinate through the board issue instead of
  silently editing the same code.

## 5. Approval semantics (what his replies mean)

On any `[merge-desk]` issue: 👍 or "approve" = approved. "revert" = revert
the resolution commit on main (via sync-push) and comment what you did. Any
other reply = instructions; treat them as a prompt, apply, comment, leave
the issue open for him to close. Silence means the auto-resolution stands.

## 6. The data is his

Every push, retry, collision, resolution, approval, and rejection lands in
`projects/merge-desk/ledger.jsonl` (knowledge-base) and in the issue trail.
The board (`second-brain serve`, Merge Desk page) renders: collisions per
week, auto-resolved vs awaiting, approved vs rejected vs reverted, and the
files that collide most (those are the refactor targets). Never send this
data anywhere outside his repos.

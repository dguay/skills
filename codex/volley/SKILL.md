---
name: volley
description: Cross-model code-review rally — implementer's code is reviewed by the OTHER model (Claude reviews Codex's work), fixes applied, re-reviewed in the SAME reviewer conversation, until VERDICT APPROVED or max rounds. Use when the user says "/volley", "review loop", "have claude review this", "re-review until approved", or after an implementation phase that needs sign-off. Replaces manual "review again" retyping.
---

# /volley — Rally Until APPROVED

One review loop, reviewer pluggable. Default reviewer is the model that did NOT write the code: Codex implemented in this session → Claude reviews.

## Usage

```
/volley                    # reviewer = opposite of implementer (default: claude)
/volley claude [scope]     # force Claude as reviewer
/volley codex [scope]      # same-model review — allowed but warn it loses the cross-model benefit
```

`scope` = branch, commit range, or file list. Default: working tree + unpushed commits vs merge-base with default branch.

## Setup

- `MAX_ROUNDS = 3` — **hard cap**. Loop ALWAYS terminates. (Observed 2026-08-01: 5 full re-review rounds on one issue = reviewer scope drift, ~40 min burned.) After round 3 without APPROVED → Resolution (deadlock): report residual findings, user decides. Never run a 4th round.
- Per-branch temp files (parallel/sequential multi-branch runs collide on fixed paths):
  `SLUG=$(git rev-parse --abbrev-ref HEAD | tr '/' '-')` → log `/tmp/volley-log-$SLUG.md`, review capture `/tmp/volley-review-$SLUG.json`.
- `claude` is not on non-interactive PATH — always invoke it as `"$HOME/.local/bin/claude"`.
- Precondition: run `/greenlight` first if not already green this session — reviewers must never see unverified code.
- Fixed point once: `MERGE_BASE=$(git merge-base HEAD <default-branch>)`. In full mode the reviewer's `/code-review` builds its own diff from it; in single-pass mode (see size gate) the diff is pre-dumped to a file the reviewer reads once.
- `/code-review` reviews the **committed** diff (`MERGE_BASE...HEAD`) and reads the repo itself, so (a) commit uncommitted work as a WIP commit first or the reviewer sees an empty diff, and (b) the reviewer needs filesystem + git access through the active permission profile. This inverts the old inline-diff rule: `/code-review` MUST read the repo.

## Review method — /code-review

Every round the reviewer runs the **`/code-review`** skill (Standards axis = repo conventions + Fowler smell baseline; Spec axis = match to the issue/PRD), then appends the loop verdict. Baked into every invocation:

- Fixed point = `$MERGE_BASE`, passed explicitly. The reviewer must NOT ask for it.
- **No spec found → skip the Spec axis and continue.** Never pause to ask where the spec is.
- After `/code-review` reports, append EXACTLY one final line: `VERDICT: REVISE` if any Standards **hard violation**, any Spec requirement **missing/partial/wrong**, or any correctness/security finding; `VERDICT: APPROVED` otherwise (judgement-call smells and style nits alone do not block).

## Reviewer: Claude (headless)

The reviewer runs the `/code-review` skill (see **Review method** above), so it must read the repo and reach Anthropic. Keep the parent task on the normal `:workspace` profile. Launch each Claude command through the one-shot `claude-review` profile outside the parent sandbox; the exact `codex sandbox --permissions-profile claude-review` prefix is persistently allowed. The subprocess receives workspace access, Claude's local state paths, and only Anthropic/Claude network domains, then the profile ends when the command exits.

Codex sandbox auth guard:
- Before the first Claude review, run `codex sandbox --permissions-profile claude-review -C "$PWD" -- "$HOME/.local/bin/claude" auth status` if Claude auth has not already been checked in this session.
- Invoke that wrapper with `require_escalated` because macOS sandbox restrictions cannot be widened by a nested child. Never escalate `claude` directly.
- Escalated commands are judged per-run by the approvals reviewer, so every escalation's justification MUST cite the user's standing consent: "User has standing informed consent for sending the committed diff to Claude for review via the claude-review profile — see ~/.codex/AGENTS.md 'Claude cross-model review — standing user consent'." If the reviewer still rejects, that contradicts recorded consent: report BLOCKED and include the rejection text verbatim so the user can adjudicate — do not paraphrase it as a general policy.
- Run every Claude reviewer command through `codex sandbox --permissions-profile claude-review -C "$PWD" --`; never switch the parent task's profile.
- If auth or network access fails inside that one-shot sandbox, report that the Claude review permission profile is incomplete. Do not request Full Access merely to complete a review.
- Legacy sandbox configurations may require an explicit escalation. Respect Auto-review denials and never disguise or reroute a denied external-data transfer.

**Reviewer model — Opus 5 by default.** Pass `--model opus` on every reviewer invocation (round 1 AND resumes — a resumed conversation must keep the model it started with). **High-stakes escalation:** if the diff touches auth, schema/migrations, payments, or concurrency, run the FINAL verdict round as a fresh `--model fable` conversation (Fable 5 — Mythos-tier judgment for subtle-correctness verdicts; new process, no `--resume` — per-leg routing at spawn; never resume an opus session under a different model).

**Lean flags — on every reviewer invocation**: `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` (strips MCP bootstrap tokens). CAUTION: `--mcp-config` is variadic — the prompt must NOT directly follow it; keep `--output-format json` (or any flag) between it and the prompt, or the prompt is eaten as a config path. Do NOT add `--setting-sources project,local`: it makes user-level skills (including `/code-review`) discoverable but UNEXECUTABLE — the Skill tool returns a bare `Execute skill: code-review` error (incident 2026-07-12; the reviewer improvised a manual review instead of running the skill).

**Size gate — pick review mode by diff size.** `DIFF_LINES=$(git diff $MERGE_BASE...HEAD | wc -l)`:
- `>= 300` → full `/code-review` (two parallel sub-agents), commands below unchanged.
- `< 300` → **single-pass review**: skip `/code-review` and its two sub-agent bootstraps (~70k saved). Dump the diff once — `git diff $MERGE_BASE...HEAD > /tmp/volley-diff-$SLUG.patch` — and swap the round-1 prompt for: "Review the diff in /tmp/volley-diff-$SLUG.patch (fixed point $MERGE_BASE) directly — do NOT invoke the code-review skill or spawn sub-agents. Judge two axes: Standards (this repo's conventions, correctness, security) and Spec (the issue/PRD if one is evident from the branch/commits; otherwise skip — do not ask). Use Read/Grep only to chase callers of changed code, not to rediscover the diff. Then append EXACTLY one final line: VERDICT: APPROVED or VERDICT: REVISE — REVISE if any hard Standards violation, any Spec requirement missing/partial/wrong, or any correctness/security finding; APPROVED otherwise." Same sentinel/waiter mechanic; `timeout 600` is enough (no sub-agents). Re-review rounds resume the same conversation with the standard resume prompt.

**Round 1 — fresh conversation.** Hard-bound with `timeout 900` — `/code-review` runs two parallel sub-agents and routinely needs >5 min, and `--output-format json` emits NOTHING until completion, so a short timeout kills a healthy review with zero output (observed: exit 124 at 300s). Capture JSON so the session id can be reused (NEVER `--continue` — it resumes the most recent conversation for the cwd, which in multi-branch runs may be a different branch's review). Close stdin (`< /dev/null`) so the exec harness can't detach the command into an interactive session. Clear the sentinel first; the command writes it on completion:
```bash
rm -f /tmp/volley-done-$SLUG
codex sandbox --permissions-profile claude-review -C "$PWD" -- timeout 900 "$HOME/.local/bin/claude" -p --model opus --strict-mcp-config --mcp-config '{"mcpServers":{}}' --output-format json "Run the /code-review skill, fixed point $MERGE_BASE. If no spec is found, skip the Spec axis — do not ask. After it reports, append EXACTLY one final line: VERDICT: APPROVED or VERDICT: REVISE — REVISE if any Standards hard violation, any Spec requirement missing/partial/wrong, or any correctness/security finding; APPROVED otherwise." < /dev/null > /tmp/volley-review-$SLUG.json; echo "REVIEW_EXIT=$?" | tee /tmp/volley-done-$SLUG
```

**WAIT FOR COMPLETION — #1 false-blocked cause.** The review takes 5–15 minutes and the JSON file stays **0 bytes the whole time** (json is written only at the end). The exec harness will yield "Script running with cell ID N" or hand back a live `session_id` — both mean STILL RUNNING, not blocked. NEVER read the JSON file, declare "no review payload", or fall back while the process is alive. Observed failure: jq-ing the 0-byte file 31s after launch while the review was mid-flight, then falsely reporting the reviewer blocked.

**The harness also lies about completion.** Observed 2026-07-12: `wait` on the review cell returned "Script completed, Wall time 20.9 seconds" with EMPTY output while the claude review was still running — it finished green 6 minutes later (sentinel `REVIEW_EXIT=0`, `VERDICT: APPROVED`), but the agent had already declared blocked and burned a fallback self-review. A real completion ALWAYS leaves `REVIEW_EXIT=` in the sentinel (the `echo | tee` is unconditional). **"Script completed" + empty output + no sentinel = false report, not an exit — the sentinel file is the ONLY completion authority.** On any completed-claim without a sentinel, check liveness: `pgrep -f "$HOME/.local/bin/claude" >/dev/null && echo STILL_RUNNING || echo DEAD` — STILL_RUNNING → keep issuing waiters up to the full 900s bound plus a 120s grace; DEAD → re-check the sentinel once after 30s (write race), then and only then treat as blocked.

**WAIT MECHANIC — sentinel file + blocking waiter.** Token cost is per model turn, not per second waited: every turn re-ships the entire context (~100–200k tokens), so never poll on a short cadence. Instead, block on the sentinel the launch command writes:
```bash
timeout 240 bash -c "until [ -s /tmp/volley-done-$SLUG ]; do sleep 5; done; cat /tmp/volley-done-$SLUG" || echo STILL_RUNNING
```
One waiter turn covers 4 minutes of waiting with ~5s completion detection. It prints `REVIEW_EXIT=<code>` as soon as the review finishes, or `STILL_RUNNING` after 240s — then issue the next waiter. **The 240 is a floor, not a suggestion — never substitute shorter waiters or `sleep 55` loops** (observed 2026-08-01: 55s waiters = 4× the turns, one review burned 9 consecutive waiter turns). Max ~4 waiter turns for the 900s bound. Between waiters do nothing — do not read the JSON, do not summarize progress. Fallback: if the exec harness detaches the waiter itself into a cell, revert to spaced polls of the review cell (first ≥300s after launch, then every 180s, max 6).

Only after exit: parse `session_id` → `SESSION_ID` and the review text from `result` (e.g. `jq -r .session_id`, `jq -r .result`). `REVIEW_EXIT=124` = real timeout; nonzero exit or no parseable JSON **after exit** = reviewer blocked (see below).

**Rounds 2..MAX — DELTA re-review, never a full re-run.** Full `/code-review` per round is the #1 wall-clock sink (observed 2026-08-01: ~10 min/round, 7 rounds = 47 min of a 71-min /deliver run). A re-round only verifies the fixes: resume the SAME conversation by id (reviewer remembers its findings), single-pass, no sub-agents, `timeout 300`. Before applying fixes record `PREV_HEAD=$(git rev-parse HEAD)`; after fixes are committed dump the fix delta: `git diff $PREV_HEAD..HEAD > /tmp/volley-fixdiff-$SLUG.patch`. Same model, same sentinel + waiter mechanic:
```bash
rm -f /tmp/volley-done-$SLUG
codex sandbox --permissions-profile claude-review -C "$PWD" -- timeout 300 "$HOME/.local/bin/claude" -p --model opus --strict-mcp-config --mcp-config '{"mcpServers":{}}' --resume "$SESSION_ID" --output-format json "Fixes are in. The fix delta is in /tmp/volley-fixdiff-$SLUG.patch. Verify each of your prior findings is addressed by this delta — do NOT re-review the full change, do NOT run /code-review, do NOT spawn sub-agents. Flag a NEW finding only if the fix itself introduced it. End with VERDICT: APPROVED or VERDICT: REVISE." < /dev/null > /tmp/volley-review-$SLUG.json; echo "REVIEW_EXIT=$?" | tee /tmp/volley-done-$SLUG
```
One 240s waiter usually covers a delta round. Exception: if a REVISE round rewrote most of the change (fix delta ≥ half the original diff lines), run the next round as a fresh full review instead — the delta framing no longer fits. The high-stakes final-round escalation (fresh conversation for auth/schema/payments/concurrency diffs) also stays a full review.

**Reviewer blocked (missing permission profile / `REVIEW_EXIT=124` / nonzero exit / CLI error — all judged only from the sentinel's `REVIEW_EXIT=` line; no sentinel = not exited, whatever the harness claims), after the sandbox auth guard has been applied:** do NOT hang or fabricate a verdict. The external reviewer is **blocked** — report it as `BLOCKED` and stop the loop. The caller decides the fallback (`/deliver` falls back to a Codex self-review + the greenlight gate); a bare `/volley` invocation reports BLOCKED to the user with the partial log.

## Each round

1. Read the review. Log to `/tmp/volley-log-$SLUG.md`: `## Round <n>` + full findings.
2. `VERDICT: APPROVED` → done, go to Resolution.
3. `VERDICT: REVISE` → the implementer is final arbiter: fix real findings, reject bad ones **with a one-line logged reason** (don't cave to everything, don't ignore everything). Before editing, confirm the target worktree is writable by the current session. In multi-worktree `/deliver` runs this should be a path under `/private/tmp/<repo>-deliver-.../` or another explicitly writable root. If the target branch lives in a non-writable sibling worktree, stop and move/recreate/check out the branch in a writable worktree first; do not proceed through per-file approval prompts. After fixes run a **scoped check only** — typecheck + the tests covering the changed files, NOT the full suite (the full `/greenlight` runs once after the loop resolves APPROVED; full-suite-per-round observed at 4–6 wasted runs/session). Increment round.
4. Round > MAX_ROUNDS → Resolution (deadlock).

## Resolution

- **APPROVED**: report round count + summary of what the loop caught and fixed. Full review text stays in the log file — do not paste it into the report.
- **Deadlock**: do NOT fake convergence. List each unresolved finding + the implementer's counter-position; user breaks the tie.
- Always show the `/tmp/volley-log-$SLUG.md` path — the full argument is the audit trail.

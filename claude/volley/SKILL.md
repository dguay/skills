---
name: volley
description: Cross-model code-review rally — implementer's code is reviewed by the OTHER model (Codex reviews Claude's work, Claude reviews Codex's), fixes applied, re-reviewed in the SAME reviewer session, until VERDICT APPROVED or max rounds. Use when the user says "/volley", "review loop", "have codex review this", "re-review until approved", or after an implementation phase that needs sign-off. Replaces manual "review again" retyping.
---

# /volley — Rally Until APPROVED

One review loop, reviewer pluggable. Default reviewer is the model that did NOT write the code: Claude implemented in this session → Codex reviews. Reviewing Codex's diff → Claude reviews (via subagent).

## Usage

```
/volley                    # reviewer = opposite of implementer (default: codex)
/volley codex [scope]      # force Codex as reviewer
/volley claude [scope]     # force Claude subagent as reviewer
/volley claude:opus [scope] # Claude reviewer with explicit model (sonnet|opus|haiku|fable)
```

`scope` = branch, commit range, or file list. Default: working tree + unpushed commits vs merge-base with default branch.

## Setup

- `MAX_ROUNDS = 3` — **hard cap**. Loop ALWAYS terminates. (Observed 2026-08-01: 5 full re-review rounds on one issue = reviewer scope drift, ~40 min burned.) After round 3 without APPROVED → Resolution (deadlock): report residual findings, user decides. Never run a 4th round.
- Before applying any round's fixes record `PREV_HEAD=$(git rev-parse HEAD)`; after fixes are committed dump the fix delta for the re-round: `git diff $PREV_HEAD..HEAD > /tmp/volley-fixdiff-$SLUG.patch`.
- Per-branch temp files (parallel /deliver workers each run /volley — fixed paths collide):
  `SLUG=$(git rev-parse --abbrev-ref HEAD | tr '/' '-')` → verdict `/tmp/volley-verdict-$SLUG.txt`, log `/tmp/volley-log-$SLUG.md`.
- `claude` is not on non-interactive PATH — always invoke it as `"$HOME/.local/bin/claude"`.
- `timeout` is not on the Bash tool PATH either (verified 2026-07-12: exit 127) — always invoke it as `/opt/homebrew/bin/timeout`.
- Precondition: run `/greenlight` first if not already green this session — reviewers must never see unverified code.
- Fixed point once: `MERGE_BASE=$(git merge-base HEAD <default-branch>)`. The reviewer's `/code-review` builds its own diff from it — no pre-built or inlined diff text needed.
- `/code-review` reviews the **committed** diff (`MERGE_BASE...HEAD`). If the work is uncommitted, make a WIP commit first (amend/squash it later) — otherwise the reviewer sees an empty diff.

## Review method — /code-review

Every round the reviewer runs the **`/code-review`** skill, then appends the loop verdict. `/code-review` reports two axes — **Standards** (repo conventions + Fowler smell baseline) and **Spec** (does it match the issue/PRD). Headless rules, baked into every invocation below:

- Fixed point = `$MERGE_BASE`, passed explicitly. The reviewer must NOT ask for it.
- **No spec found → skip the Spec axis and continue.** Never pause to ask where the spec is.
- The reviewer runs `git diff` itself → needs repo read + git access. Run it outside any sandbox that can't reach the worktree.
- After `/code-review` reports, the reviewer appends EXACTLY one final line:
  - `VERDICT: REVISE` if any Standards **hard violation**, any Spec requirement **missing/partial/wrong**, or any correctness/security finding.
  - `VERDICT: APPROVED` otherwise — judgement-call smells and style nits alone do not block.

## Reviewer: Codex

**Model & effort.** Default profile (Terra) — no `--profile` flag. Round 1 gets `-c model_reasoning_effort=high`: review is judgment, not typing; high effort on the workhorse is cheaper than Sol at near-tie quality (A/B 2026-07). Delta rounds get `-c model_reasoning_effort=medium` — verifying a fix checklist, not discovery. Effort is per-invocation config, safe to lower on resume; the model itself must stay the conversation's model. **High-stakes escalation:** diff touches auth, schema/migrations, payments, or concurrency → run the FINAL verdict round as a fresh `--profile sol` session (new session, never a resume under a different profile).

**Round 1 — fresh session, capture thread_id (hard-bound: `timeout 600`):**
```bash
/opt/homebrew/bin/timeout 600 codex exec -s read-only -c model_reasoning_effort=high --json -o /tmp/volley-verdict-$SLUG.txt \
  "Run the /code-review skill, fixed point $MERGE_BASE. If no spec is found, skip the Spec axis — do not ask. After it reports, append EXACTLY one final line: VERDICT: APPROVED or VERDICT: REVISE — REVISE if any Standards hard violation, any Spec requirement missing/partial/wrong, or any correctness/security finding; APPROVED otherwise." \
  2>/dev/null | grep '"type":"thread.started"'
```
Parse `thread_id` → `THREAD_ID`. No `thread.started` line and no verdict file = run failed (auth/model) — stop, tell the user.

**Rounds 2..MAX — DELTA re-review, never a full re-run** (full re-review per round is the #1 wall-clock sink — observed ~10 min/round; a delta round is ~2). Resume SAME session (reviewer remembers prior findings), `timeout 300`:
```bash
# resume rejects -s; -c sandbox_mode is REQUIRED or Codex inherits config.toml
# and could write files.
/opt/homebrew/bin/timeout 300 codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" -c model_reasoning_effort=medium --json \
  -o /tmp/volley-verdict-$SLUG.txt \
  "Fixes are in. The fix delta is in /tmp/volley-fixdiff-$SLUG.patch. Verify each of your prior findings is addressed by this delta — do NOT re-review the full change, do NOT re-run /code-review. Flag a NEW finding only if the fix itself introduced it. End with VERDICT: APPROVED or VERDICT: REVISE." \
  2>/dev/null >/dev/null
```
**Rewrite exception:** if a REVISE round rewrote most of the change (fix delta ≥ half the original diff lines), the delta framing no longer fits — run the next round full-scope BUT **single-pass** (fresh session, whole diff from `$MERGE_BASE`, no `/code-review` re-run), `timeout 600`. Full scope is about WHAT gets reviewed, not the review machinery — measured 2026-08-01: skill-driven full re-round 17–20 min vs single-pass 5–6 min, same diff sizes.

## Reviewer: Claude

Run the review in a **fresh headless `claude -p`**, NOT a subagent: full-mode `/code-review` spawns its own two parallel sub-agents, which `caveman:cavecrew-reviewer` (no Agent tool) and nested subagents can't do.

Model: if the user wrote `claude:<model>` (sonnet|opus|haiku|fable), add `--model <model>`; otherwise `--model opus` (Opus 5). **High-stakes escalation:** diff touches auth, schema/migrations, payments, or concurrency → run the FINAL verdict round as a fresh `--model fable` conversation (Fable 5; new process, not `--continue` — never resume a conversation under a different model).

**Lean flags — on every reviewer invocation**: `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` (strips MCP bootstrap tokens). CAUTION: `--mcp-config` is variadic — never let the prompt directly follow it; keep another flag between them or the prompt is eaten as a config path. Do NOT add `--setting-sources project,local`: it makes user-level skills (including `/code-review`) discoverable but UNEXECUTABLE — the Skill tool returns a bare `Execute skill: code-review` error (incident 2026-07-12).

**Size gate:** `DIFF_LINES=$(git diff $MERGE_BASE...HEAD | wc -l)`.
- `>= 300` → full `/code-review`, `timeout 900` — two sub-agents, routinely needs >5 min; a shorter bound kills a healthy review with no output.
- `< 300` → **single-pass review** (no /code-review, no sub-agents — saves ~70k bootstrap + duplicate diff reads): `git diff $MERGE_BASE...HEAD > /tmp/volley-diff-$SLUG.patch`, then swap the round-1 prompt for the single-pass prompt below. `timeout 600`.

**Round 1 — fresh conversation (full mode):**
```bash
/opt/homebrew/bin/timeout 900 "$HOME/.local/bin/claude" -p --model opus --strict-mcp-config --mcp-config '{"mcpServers":{}}' --output-format text "Run the /code-review skill, fixed point $MERGE_BASE. If no spec is found, skip the Spec axis — do not ask. After it reports, append EXACTLY one final line: VERDICT: APPROVED or VERDICT: REVISE — REVISE if any Standards hard violation, any Spec requirement missing/partial/wrong, or any correctness/security finding; APPROVED otherwise."
```
**Round 1 single-pass prompt (same flags, `timeout 600`):** "Review the diff in /tmp/volley-diff-$SLUG.patch (fixed point $MERGE_BASE) directly — do NOT invoke the code-review skill or spawn sub-agents. Judge two axes: Standards (this repo's conventions, correctness, security) and Spec (the issue/PRD if evident from branch/commits; otherwise skip — do not ask). Use Read/Grep only to chase callers of changed code, not to rediscover the diff. Append EXACTLY one final line: VERDICT: APPROVED or VERDICT: REVISE — REVISE if any hard Standards violation, any Spec requirement missing/partial/wrong, or any correctness/security finding; APPROVED otherwise."

**Rounds 2..MAX — DELTA re-review, never a full re-run** (same flags, either mode; continue the SAME conversation, `timeout 300`, no sub-agents):
```bash
/opt/homebrew/bin/timeout 300 "$HOME/.local/bin/claude" -p --model opus --strict-mcp-config --mcp-config '{"mcpServers":{}}' --output-format text --continue "Fixes are in. The fix delta is in /tmp/volley-fixdiff-$SLUG.patch. Verify each of your prior findings is addressed by this delta — do NOT re-review the full change, do NOT run /code-review, do NOT spawn sub-agents. Flag a NEW finding only if the fix itself introduced it. End with VERDICT: APPROVED or VERDICT: REVISE."
```
**Rewrite exception:** fix delta ≥ half the original diff lines → delta framing no longer fits; next round is full-scope BUT **single-pass** (fresh conversation, whole diff pre-dumped to `/tmp/volley-diff-$SLUG.patch`, the single-pass prompt above, `timeout 600` — never full `/code-review`, regardless of diff size; measured 2026-08-01: sub-agent full re-round 17–20 min vs single-pass 5–6 min).

## Each round

1. Read the review. Log to `/tmp/volley-log-$SLUG.md`: `## Round <n>` + full findings.
2. `VERDICT: APPROVED` → done, go to Resolution.
3. `VERDICT: REVISE` → the implementer is final arbiter: fix real findings, reject bad ones **with a one-line logged reason** (don't cave to everything, don't ignore everything). After fixes run a **scoped check only** — typecheck + the tests covering the changed files, NOT the full suite (the full `/greenlight` runs once after the loop resolves APPROVED; full-suite-per-round observed at 4–6 wasted runs/session). Increment round.
4. Round > MAX_ROUNDS → Resolution (deadlock).

## Resolution

- **APPROVED**: report round count + summary of what the loop caught and fixed.
- **Deadlock**: do NOT fake convergence. List each unresolved finding + the implementer's counter-position; user breaks the tie.
- Always show the `/tmp/volley-log-$SLUG.md` path — the full argument is the audit trail.
- Never stop/kill a running dev server on your own (e.g. re-running the check command needs the port). If a step requires the dev server stopped, ask the user for approval first.

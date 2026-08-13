---
name: deliver
description: Full-implementation pipeline for GitHub issues — fetch issue, branch, TDD, /greenlight verification gate, /volley cross-model review loop (Claude reviews), commit "fixes #N", push. Multiple issue numbers run in parallel via git worktrees + background codex exec workers (cap 3), then the main agent merges all worker branches into one batch branch and opens a single PR (avoids post-merge conflicts between per-issue PRs). Use when the user says "/deliver N", "deliver issues 42 87", "implement issue #N end to end", or wants an issue taken from number to reviewed pushed branch.
disable-model-invocation: true
---

# /deliver — Issue Number In, Reviewed Branch Out

Pipeline per issue: fetch → branch → TDD → verify → review → commit → push → PR. Nothing ships unverified or unreviewed.

## Usage

```
/deliver 42            # one issue, inline
/deliver 42 87 91      # N issues, parallel worktree workers (cap 3)
/deliver 42 --no-push  # stop after commit
```

Before choosing inline or multi-issue mode, initialize the durable run ledger so even a single-issue run that fails early is diagnosable: `RUNID=$(date +%s); RUN_DIR="$HOME/.deliver-runs/$RUNID"; mkdir -p "$RUN_DIR"; LEDGER="$RUN_DIR/timeline.tsv"`.

## Per-issue pipeline (the worker's job)

1. **Fetch**: `gh issue view N --json title,body,labels,comments`. If ambiguous or missing acceptance criteria, derive them from the body and state them explicitly before coding — do not silently guess.
2. **Branch**: `git checkout -b fix/N-<kebab-slug-from-title>` off the default branch (fresh `git pull` first).
3. **Implement via /tdd**: red test from the issue's acceptance criteria first, then green, then refactor.
4. **Verify via /greenlight**: mandatory gate. RED → fix and re-run. Never proceed to review on RED.
5. **Review via /volley** (default reviewer: claude, since Codex implemented). Bounded by **Reviewer reachability & fallback** (above): reviewer runs `/code-review` against the merge-base, hard timeout, honest fallback to Codex `/code-review` self-review if the external reviewer blocks — never stall or fabricate a verdict. Deadlock → stop this issue, report unresolved findings, do NOT push. *Multi-issue mode: skip — a `codex exec` worker cannot spawn the reviewer; review is deferred to the integration phase. See below.*
   - The committed candidate reviewed in round 1 already uses the final conventional message ending in `fixes #N`; do not amend an approved commit merely to change its message.
   - If any REVISE round changed code: re-run **/greenlight** after APPROVED, before commit. RED → fix and re-run; do not commit on RED.
   - **Full-suite budget: the full verify suite runs exactly twice per branch's lifecycle** — once as the step-4 gate before review, once after final APPROVED (skip the second if no REVISE round changed code). Between REVISE rounds: scoped checks only (typecheck + tests covering changed files), per volley's round rules. Never run the full suite per round.
6. **Finalize the approved commit**: `/volley` returns `REVIEWED_HEAD`. Run `"$HOME/.codex/skills/deliver/assert-reviewed-head.sh" "$REVIEWED_HEAD" "before final commit"`. The candidate/fix commit is already final and contains only in-scope files; do not amend or add a post-approval commit. Unexpected drift invalidates the approval: report both SHAs and review the new HEAD instead of proceeding.
7. **Push** branch (unless `--no-push`). Immediately before pushing, run the same assertion with checkpoint `before push`. Any forced update must use `git push --force-with-lease`; never use unqualified `--force`. Report branch name. *Multi-issue mode: skip — workers stop after commit; the main agent integrates and pushes (see below).*
8. **PR**: if everything is good to go (greenlight GREEN, volley APPROVED, pushed), create the PR:
   ```
   gh pr create --base <default-branch> --head fix/N-<slug> --title "<issue title>" --body "fixes #N"
   ```
   Skip on `--no-push`, RED, or deadlock. Report PR URL in the final report. *Multi-issue mode: skip — one batch PR is created by the main agent.*

**Scope guard**: never touch `.env*`, `package.json`, lockfiles, or CI config unless the issue explicitly requires it — if it does, call it out in the final report.

## Reviewer reachability & fallback

Review runs the **`/code-review`** skill (Standards + Spec, two parallel sub-agents), NOT a freeform adversarial prompt. Both Claude and Codex have it (`~/.claude/skills/code-review`, `~/.agents/skills/code-review`). `/code-review` computes its own diff and reads the repo, so the reviewer needs worktree + git access — the flaky part under a Codex runtime is reaching a logged-in `claude` that can read the worktree without going silent. Do NOT let it stall the run or fabricate a verdict. Rules:

1. **Reviewer runs `/code-review`, fixed point = merge-base.** `MERGE_BASE=$(git merge-base HEAD <default-branch>)`. Because `/code-review` reviews the **committed** diff (`MERGE_BASE...HEAD`), make the candidate commit before review with its final conventional message ending in `fixes #N`; do not plan a post-approval amend. Keep the parent task on `:workspace`; launch `codex sandbox --permissions-profile claude-review -C "$PWD" --` with `require_escalated` so only the reviewer subprocess receives Claude state and Anthropic network access. Never escalate `claude` directly. Every escalation's justification MUST cite the user's standing consent (see ~/.codex/AGENTS.md "Claude cross-model review — standing user consent"); if the approvals reviewer rejects anyway, report BLOCKED with the rejection text verbatim — do not paraphrase it as a general policy. Instruct it: pass fixed point `$MERGE_BASE`, skip the Spec axis if no spec is found (do not ask), then append EXACTLY one line — `VERDICT: REVISE` if any Standards hard violation, any Spec requirement missing/partial/wrong, or any correctness/security finding; `VERDICT: APPROVED` otherwise.
2. **Launch visibly; delegate post-launch completion to the waiter.** Set `REVIEW_HEAD=$(git rev-parse HEAD)` and `REVIEW_STARTED_AT=$(date +%s)`, then run `"$HOME/.codex/skills/volley/wait-review.sh" prepare --sentinel /tmp/volley-done-$SLUG --result /tmp/volley-review-$SLUG.json`. Keep the escalated launch legible: `codex sandbox --permissions-profile claude-review -C "$PWD" -- timeout 900 "$HOME/.local/bin/claude" -p --model opus --strict-mcp-config --mcp-config '{"mcpServers":{}}' --output-format json "Run /code-review, fixed point $MERGE_BASE ... VERDICT ..." < /dev/null > /tmp/volley-review-$SLUG.json; echo "REVIEW_EXIT=$?" | tee /tmp/volley-done-$SLUG`. Do NOT add `--setting-sources project,local`: it made user-level `/code-review` discoverable but unexecutable in the 2026-07-12 incident. Diffs under 300 lines use volley's single-pass mode and `timeout 600`; round 1 otherwise uses `timeout 900`, delta rounds use the same conversation with `--resume "$SESSION_ID"` and `timeout 300`, and the hard cap remains 3 rounds. Opus 5 is the default; auth/schema/migrations/payments/concurrency get a fresh Fable 5 final verdict round. After launch, the only completion command is:
   ```bash
   "$HOME/.codex/skills/volley/wait-review.sh" wait --sentinel /tmp/volley-done-$SLUG --result /tmp/volley-review-$SLUG.json --ledger "$LEDGER" --issue "$ISSUE" --round "$ROUND" --reviewed-head "$REVIEW_HEAD" --process-pattern "$HOME/.local/bin/claude"
   ```
   It waits on the 240-second floor, checks liveness, rejects empty/unparseable JSON, parses `SESSION_ID`/`VERDICT`/`REVIEWED_HEAD`, and appends the verdict to the durable ledger. If the harness falsely claims completion without a sentinel, add `--completion-claimed --started-at "$REVIEW_STARTED_AT" --bound 900 --grace 120`; do not substitute manual polling. A nonzero waiter result means the external reviewer is BLOCKED. For a REVISE round, apply fixes but immediately before committing them assert `HEAD == REVIEWED_HEAD` with the deliver guard; drift invalidates the verdict and starts a fresh review.
3. **On blocked → fall back, don't stall.** Set `REVIEW_HEAD=$(git rev-parse HEAD)` before running a Codex self-review with the same skill: `codex exec -s read-only "Run /code-review, fixed point $MERGE_BASE. Skip Spec if no spec. End with VERDICT: APPROVED or VERDICT: REVISE."` as the review of record. When it returns a verdict, set `REVIEWED_HEAD=$REVIEW_HEAD` and append both the verdict and reviewed-head rows to `$LEDGER`, just as the waiter does for Claude. Combined with the already-green `/greenlight` gate, that's the sign-off. If `HEAD` moved during the self-review, the normal guard invalidates it.
4. **Report honestly.** Record the actual reviewer in the Volley column — `APPROVED (claude r2)`, `APPROVED (codex-self, claude blocked)`, or `deadlock`. Never write APPROVED for a review that did not run.

## Multiple issues — parallel worktree workers

> **Why `codex exec --cd`, not a Codex subagent:** Codex subagents (`~/.codex/agents/*.toml`) have no per-agent `cwd`/worktree field — they run as threads in the *same* workspace, so parallel git-branch work would collide. `codex exec --cd <worktree>` is the only primitive that gives each worker an isolated working dir + branch. Verified against OpenAI subagent docs 2026-07. (A subagent is still fine *inside* a worker for read-only exploration/review, where isolation doesn't matter.)

- Put all multi-issue worktrees under a writable scratch root, not as sibling directories. Default to `/private/tmp/<repo>-deliver-<N1>-<N2>-.../` on macOS/Codex because `/private/tmp` is writable to the main session and to worker sessions. Do not use `../<repo>-fix-N` unless that parent directory is explicitly part of the current session's writable roots; otherwise the integration-phase `/volley` fixes will trigger per-file edit approvals when the main agent touches those worktrees.
- For each issue: `git worktree add /private/tmp/<repo>-deliver-<N1>-<N2>-.../<repo>-fix-N -b fix/N-<slug>`, then **make dependencies resolve in the worktree before launching the worker** — a fresh worktree has no `node_modules`, so `/greenlight` goes RED on unresolved imports (TS/esbuild) for reasons unrelated to the issue. Symlink the installed deps from the main checkout instead of reinstalling:
  ```bash
  ln -s "$(git -C . rev-parse --show-toplevel)/node_modules" /private/tmp/<repo>-deliver-<N1>-<N2>-.../<repo>-fix-N/node_modules   # JS/TS
  ```
  These are gitignored — never staged. Non-JS projects: run the project's install/sync command in the worktree, or symlink the equivalent dep dir (`.venv`, `vendor/`, `target/`). Then launch the background worker:
  ```bash
  codex exec --cd /private/tmp/<repo>-deliver-<N1>-<N2>-.../<repo>-fix-N \
    --sandbox workspace-write \
    --ephemeral \
    --add-dir "$HOME/.codex" \
    -o /private/tmp/<repo>-deliver-<N1>-<N2>-.../<repo>-fix-N/.deliver-result.txt \
    "Run the /deliver per-issue pipeline for issue #N, steps 1-4 and 6 ONLY (fetch, branch, tdd, greenlight, commit). Do NOT run step 5 (/volley review) — the main agent reviews after you return. Do NOT push, do NOT create a PR. Final line: RESULT: {issue, branch, tdd, greenlight}."
  ```
  - `--ephemeral` stops the worker from persisting session/rollout files to `~/.codex/sessions/` — that write lands *outside* the worktree workspace and the sandbox blocks it, which is what kills workers with "could not write its own local state" before any repo work. `--add-dir "$HOME/.codex"` is belt-and-suspenders for any residual state write; `-o …/.deliver-result.txt` captures the RESULT line reliably instead of scraping stdout.
- **Max 3 concurrent** (known worker-death risk at higher counts — do not raise cap until diagnosed). More than 3 issues → batches of 3.
- Worker returns nothing or dies → retry ONCE with a fresh worker in the same worktree (keep `--ephemeral`; do NOT drop the sandbox — with `--ephemeral` the state-write failure is already gone, so a second death is a real failure, not a sandbox artifact). Second death → mark FAILED, move on, report it.
- Workers must not touch each other's branches; each commits only to its own `fix/N-*`. Clean up worktrees (`git worktree remove`) only after the integration phase has merged that branch (the branch survives worktree removal; just don't remove a worktree with uncommitted work).

### Integration phase (main agent, after all workers return)

Per-issue PRs off the same base conflict as soon as the first one merges, so
multi-issue runs produce ONE batch PR:

1. **Review each worker branch — reviews are PARALLEL and PIPELINED.** Workers committed but were NOT reviewed. Two rules that dominate wall clock:
   - **Pipeline:** launch a branch's round-1 review as soon as ITS worker returns GREEN — do not wait for the whole batch (staggered workers otherwise waste ~10 min of dead reviewer time).
   - **Parallel:** every branch's reviewer is an independent `codex sandbox … claude -p` process against its own worktree with its own `$SLUG` sentinel — nothing serializes them. Never hold branch B's review until branch A's verdict; keep all pending reviews in flight and service verdicts (fix → delta re-round) as each waiter returns. In one shell/tool call, start one `wait-review.sh wait ...` process per outstanding review in the background and `wait`; do not reimplement an any-sentinel loop or inspect result files directly.
   For each branch that reported greenlight GREEN, review the diff — the reviewer path is time-bounded and has an honest fallback, because the cross-CLI reviewer frequently hangs or can't reach the worktree. Follow **Reviewer reachability & fallback** (above). If a REVISE round changes code on a branch, re-run `/greenlight` on that branch after APPROVED, before including it (scoped checks between rounds — see the full-suite budget rule). Deadlock or round cap (3) hit on a branch → exclude and report it.
   - Before applying any `VERDICT: REVISE` fixes, confirm the branch worktree path is inside the current session's writable roots (`pwd` under `/private/tmp`, the project root, or another explicitly writable root). If it is not writable, do not grind through per-file approvals. Move/recreate the branch worktree under the writable scratch root, or check out the branch in a writable batch worktree, then apply fixes there.
2. Include only branches that finished clean (greenlight GREEN + volley APPROVED in step 1). Before merging each included branch, run the approval guard in that branch's worktree against its `REVIEWED_HEAD`; a late worker/retry commit invalidates approval and must be re-reviewed. Failed/deadlocked/RED/drifted issues are excluded and reported — they never block the rest of the batch.
3. Create the integration branch in a writable worktree under the same scratch root: `git worktree add /private/tmp/<repo>-deliver-<N1>-<N2>-.../<repo>-batch -b deliver/batch-<N1>-<N2>-... <default-branch>` (fresh `git pull` first). Use an in-place `git checkout -b ...` only when the current checkout is intentionally the integration workspace and is clean.
4. Merge each worker branch in, one at a time with `git merge --no-ff fix/N-<slug>`. A clean merge adds no code and gets no extra review. On conflict, resolve it yourself, stage the resolution, finish the merge commit, and record the files/issues in the report. Then dump only the hand-written combined resolution with `git show --cc --format= HEAD > /tmp/volley-resolution-$SLUG.patch` and run one fresh **single-pass** review of that patch (no `/code-review`, no sub-agents) through the normal visible Claude launch plus `wait-review.sh`, recording `REVIEW_HEAD=$(git rev-parse HEAD)` first. APPROVED → retain that resolution SHA; REVISE → fix, assert against the reviewed SHA before committing, and run one final delta verdict; BLOCKED/deadlock → do not push the batch. This conditional is mandatory: a deliberately conflicting batch enters it, while a clean batch does not create a review round.
5. After all merges and any required resolution reviews, re-run **/greenlight** on the combined batch branch — merges can break what each branch passed alone. RED → fix and re-run; never push RED. A RED fix is new code: commit it and review that delta before treating the batch as approved.
6. Before batch push, repeat the exact-HEAD guard in every source worktree and verify each reviewed resolution commit is an ancestor of batch `HEAD`. Drift invalidates the relevant approval. Push the batch branch (unless `--no-push`) and open one PR; any forced update uses `--force-with-lease`, never unqualified `--force`:
   ```
   gh pr create --base <default-branch> --head deliver/batch-... --title "Deliver #N1, #N2, ..." --body "fixes #N1
   fixes #N2
   ..."
   ```
   One `fixes #N` per line so GitHub closes every issue on merge.
7. Single-issue runs are unchanged: steps 5, 7–8 of the per-issue pipeline apply inline, no batch branch.

## Run ledger (timing)

At absolute run start, before branching between single- and multi-issue modes: `RUNID=$(date +%s); RUN_DIR="$HOME/.deliver-runs/$RUNID"; mkdir -p "$RUN_DIR"; LEDGER="$RUN_DIR/timeline.tsv"`. Append one line at every phase transition (issue = `N`, or `batch`/`run` for non-issue phases):

```bash
echo "$(date +%s)	$ISSUE	$PHASE	$DETAIL" >> "$LEDGER"
```

Phases: `worker_start`, `worker_done`, `review_r<N>_start`, `review_r<N>_verdict` (detail = APPROVED/REVISE/BLOCKED), `review_r<N>_reviewed_head` (detail = reviewed SHA), `greenlight_start`, `greenlight_end` (detail = GREEN/RED/scoped), `merge`, `push`. Cheap — one append per transition; never skip it. Sentinel, diff, fix-delta, and resolution patch files remain disposable under `/tmp` and slug-keyed; only the run ledger is durable. On failure paths (deadlock, worker death, BLOCKED reviewer) include the raw timeline in the final report — failures are exactly when the timeline matters. `~/bin/deliver-stats "$LEDGER"` prints the phase-duration table, including after a reboot.

## Final report

Always end with the status table, one row per issue. Rounds / Review min / Verify runs come from the ledger — they make a pathological run (5 rounds, 38 review minutes) visible without log archaeology:

```
| Issue | Branch        | TDD  | Greenlight | Volley          | Rounds | Review min | Verify runs | In batch | PR   |
|-------|---------------|------|------------|-----------------|--------|------------|-------------|----------|------|
| #42   | fix/42-...    | pass | GREEN      | APPROVED (r2)   | 2      | 14         | 2 full + 1 scoped | yes | #123 |
| #87   | fix/87-...    | pass | RED        | —               | 0      | 0          | 1 full      | no       | —    |
```

Below the table print the timeline path: `Timeline: $HOME/.deliver-runs/$RUNID/timeline.tsv`.

Multi-issue: PR column shows the single batch PR; add one line below the table for the batch — branch name, combined greenlight result, conflicts resolved (which files, between which issues). Single-issue: "In batch" column is "—".

Plus per-issue notes: manual steps the user must do, scope-guard exceptions, deadlocked findings. Failures reported plainly — a partial delivery is reported as partial, never rounded up to done.

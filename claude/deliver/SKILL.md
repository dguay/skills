---
name: deliver
description: Full-implementation pipeline for GitHub issues — fetch issue, branch, TDD, /greenlight verification gate, /volley cross-model review loop, commit "fixes #N", push. Multiple issue numbers spin up parallel worker subagents in isolated worktrees (cap 3), then the main agent merges all worker branches into one batch branch and opens a single PR (avoids post-merge conflicts between per-issue PRs). Use when the user says "/deliver N", "deliver issues 42 87", "implement issue #N end to end", or wants an issue taken from number to reviewed pushed branch.
disable-model-invocation: true
---

# /deliver — Issue Number In, Reviewed Branch Out

Pipeline per issue: fetch → branch → TDD → verify → review → commit → push → PR. Nothing ships unverified or unreviewed.

## Usage

```
/deliver 42                        # one issue, inline
/deliver 42 87 91                  # N issues, parallel workers in worktrees (cap 3)
/deliver 42 --no-push              # stop after commit
/deliver 42 --reviewer claude:opus # force reviewer, passed through to /volley
                                   # (codex | claude | claude:<sonnet|opus|haiku|fable>)
```

## Step 0 — Reviewer preflight (run before any other work)

Verify the reviewer CLI for this run is installed and logged in, so the
review step can't fail late with a not-logged-in error.

1. Determine which reviewer this run will use: `--reviewer` value if given, else codex.
2. Run the matching check:
   - Claude: `"$HOME/.local/bin/claude" auth status --json` — require exit code 0 AND
     `"loggedIn": true` in the output. (Absolute path: `claude` is not on
     non-interactive PATH.)
   - Codex: `codex login status` — require exit code 0.
   A missing binary makes the command fail; treat that as the same failure.
3. If the check fails, STOP. Do not start implementation. Tell the user
   which reviewer is unavailable and the fix:
   - Claude: run `claude auth login`
   - Codex: run `codex login`
4. Proceed with the rest of /deliver only once the check passes.

## Per-issue pipeline (the worker's job)

1. **Fetch**: `gh issue view N --json title,body,labels,comments`. If ambiguous or missing acceptance criteria, derive them from the body and state them explicitly before coding — do not silently guess.
2. **Branch**: `git checkout -b fix/N-<kebab-slug-from-title>` off the default branch. *Single-issue mode: `git pull` first. Multi-issue mode: do NOT pull — the main agent already did, before spawning (see below); branch off the base it fetched.*
3. **Implement via /tdd**: red test from the issue's acceptance criteria first, then green, then refactor.
4. **Verify via /greenlight**: mandatory gate. RED → fix and re-run. Never proceed to review on RED.
5. **Review via /volley** (default reviewer: codex, since Claude implemented; `--reviewer` overrides — invoke as `/volley <reviewer>`). The reviewer runs the **`/code-review`** skill (Standards + Spec) — it reviews the committed diff, so /volley makes a WIP commit first if the work is uncommitted (amend it at step 6). Runs to APPROVED or deadlock. Deadlock → stop this issue, report unresolved findings, do NOT push.
   - If any REVISE round changed code: re-run **/greenlight** after APPROVED, before commit. RED → fix and re-run; do not commit on RED.
   - **Full-suite budget: the full verify suite runs exactly twice per branch's lifecycle** — once as the step-4 gate before review, once after final APPROVED (skip the second if no REVISE round changed code). Between REVISE rounds: scoped checks only (typecheck + tests covering changed files), per volley's round rules. Never run the full suite per round.
6. **Commit**: caveman-commit style, body ends with `fixes #N`. Only files in scope. If /volley left a WIP commit, amend/finalize it here.
7. **Push** branch (unless `--no-push`). Report branch name. *Multi-issue mode: skip — workers stop after commit; the main agent integrates and pushes (see below).*
8. **PR**: if everything is good to go (greenlight GREEN, volley APPROVED, pushed), create the PR:
   ```
   gh pr create --base <default-branch> --head fix/N-<slug> --title "<issue title>" --body "fixes #N"
   ```
   Skip on `--no-push`, RED, or deadlock. Report PR URL in the final report. *Multi-issue mode: skip — one batch PR is created by the main agent.*

**Scope guard**: never touch `.env*`, `package.json`, lockfiles, or CI config unless the issue explicitly requires it — if it does, call it out in the final report. Never stop/kill a running dev server on your own — if a step (greenlight, build, smoke) requires it stopped, ask the user for approval first.

## Multiple issues — parallel workers

- **Pull once, in the main agent, before spawning anything**: `git checkout <default-branch> && git pull`. Worktrees have their own index but share one `.git` — object store, refs, `packed-refs`. Concurrent worker pulls contend on those shared ref locks, and a worker that loses the race dies on a failed git command. Nothing needs each worker to fetch, so the sharing is removed rather than serialized.
- Spawn one general-purpose agent per issue with `isolation: worktree`, **max 3 concurrent** (known worker-death risk at higher counts — do not raise cap until diagnosed). More than 3 issues → batches of 3.
- Each worker prompt = the per-issue pipeline above (steps 1–6 only: stop after commit, no push, no PR) + the issue number + the `--reviewer` value if given + instruction to return a structured result: `{issue, branch, tdd: pass/fail, greenlight: GREEN/RED, volley: APPROVED/deadlock/rounds, notes}`.
- Worker returns nothing or dies → retry ONCE with a fresh worker. Second death → mark FAILED, move on, report it.
- Workers must not touch each other's branches; each commits only to its own `fix/N-*`.

### Integration phase (main agent, after all workers return)

Per-issue PRs off the same base conflict as soon as the first one merges, so
multi-issue runs produce ONE batch PR:

1. Include only branches that finished clean (greenlight GREEN + volley APPROVED). Failed/deadlocked issues are excluded and reported — they never block the rest of the batch.
2. `git checkout -b deliver/batch-<N1>-<N2>-... <default-branch>` (fresh `git pull` first).
3. Merge each worker branch in, one at a time: `git merge --no-ff fix/N-<slug>`. Conflict → resolve it yourself (main-agent judgment; both sides were reviewed, so pick the combination that preserves both issues' behavior). Note every conflict resolved in the final report.
4. Re-run **/greenlight** on the combined batch branch — merges can break what each branch passed alone. RED → fix and re-run; never push RED.
5. Push the batch branch (unless `--no-push`) and open one PR:
   ```
   gh pr create --base <default-branch> --head deliver/batch-... --title "Deliver #N1, #N2, ..." --body "fixes #N1
   fixes #N2
   ..."
   ```
   One `fixes #N` per line so GitHub closes every issue on merge.
6. Single-issue runs are unchanged: steps 7–8 of the per-issue pipeline apply, no batch branch.

## Run ledger (timing)

At run start: `RUNID=$(date +%s); mkdir -p /tmp/deliver-$RUNID`, and pass the path to every worker. Main agent and workers append one line at every phase transition (issue = `N`, or `batch`/`run` for non-issue phases):

```bash
# WRITER = the issue number for a worker, "main" for the main agent.
echo "$(date +%s)	$ISSUE	$PHASE	$DETAIL" >> /tmp/deliver-$RUNID/timeline-$WRITER.tsv
```

**One shard per writer, never a shared file.** Up to 3 workers plus the main
agent write the ledger concurrently; a single `timeline.tsv` would make them
one shared writer for no benefit, since nothing reads the ledger mid-run.
Each writer owns its own path, so there is nothing to serialize.

Merge on read, at report time only (`sort -n` restores the interleaved
chronology `deliver-stats` expects):

```bash
sort -n /tmp/deliver-$RUNID/timeline-*.tsv > /tmp/deliver-$RUNID/timeline.tsv
```

Phases: `worker_start`, `worker_done`, `review_r<N>_start`, `review_r<N>_verdict` (detail = APPROVED/REVISE/BLOCKED), `greenlight_start`, `greenlight_end` (detail = GREEN/RED/scoped), `merge`, `push`. Cheap — one echo per transition; never skip it. Merge the shards before reading or reporting the timeline. On failure paths (deadlock, worker death, BLOCKED reviewer) include the raw timeline in the final report — failures are exactly when the timeline matters. `~/bin/deliver-stats /tmp/deliver-$RUNID/timeline.tsv` prints the phase-duration table.

## Final report

Always end with the status table, one row per issue. Rounds / Review min / Verify runs come from the ledger — they make a pathological run (5 rounds, 38 review minutes) visible without log archaeology:

```
| Issue | Branch        | TDD  | Greenlight | Volley          | Rounds | Review min | Verify runs | In batch | PR   |
|-------|---------------|------|------------|-----------------|--------|------------|-------------|----------|------|
| #42   | fix/42-...    | pass | GREEN      | APPROVED (r2)   | 2      | 14         | 2 full + 1 scoped | yes | #123 |
| #87   | fix/87-...    | pass | RED        | —               | 0      | 0          | 1 full      | no       | —    |
```

Below the table print the timeline path: `Timeline: /tmp/deliver-$RUNID/timeline.tsv`.

Multi-issue: PR column shows the single batch PR; add one line below the table for the batch — branch name, combined greenlight result, conflicts resolved (which files, between which issues). Single-issue: "In batch" column is "—".

Plus per-issue notes: manual steps the user must do, scope-guard exceptions, deadlocked findings. Failures reported plainly — a partial delivery is reported as partial, never rounded up to done.

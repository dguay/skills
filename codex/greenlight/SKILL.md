---
name: greenlight
description: Verification gate — run the project's check command + smoke script, read runtime logs, and block any "done" claim until everything is green. Use when the user says "/greenlight", "verify this works", "prove it", or before claiming any edit is complete. Also invoked as a mandatory gate by /deliver and before /volley review rounds.
---

# /greenlight — No Done Without Green

Run every check the project defines. Report GREEN or RED per check. A RED result means the work is NOT done — say so plainly, never soften it.

## Usage

```
/greenlight              # run all checks for the current project
/greenlight <path>       # run checks for a specific project dir
```

## Procedure

### 1. Resolve the checks (in priority order)

1. **Project AGENTS.md / CLAUDE.md** — look for a "check command", "verify", or "smoke" instruction. This wins over everything below.
2. **Smoke script** — first match of: `scripts/smoke.*`, `.claude/smoke.*`, `smoke.sh` in repo root.
3. **Detected defaults** from `package.json` scripts (run all that exist): `typecheck` (else `tsc --noEmit` if tsconfig.json exists), `test`, `lint`, `build`. Use the project's package manager (lockfile: pnpm-lock → pnpm, bun.lock → bun, yarn.lock → yarn, else npm).
4. **Python**: `pytest` if tests/ or test_*.py exists; `ruff check` if configured.

If NOTHING is found: say so, propose the 1-2 commands that would apply, and ask the user to confirm once — then offer to write them into the project's AGENTS.md so this never gets asked again.

### 2. Runtime-invisible projects — logs are part of the gate

If the project touches a runtime the agent can't execute directly, checks alone don't prove it works. Also do:

- **Supabase edge functions / DB**: after deploy or migration, read logs (`supabase functions logs <fn>` or the Supabase MCP get_logs tool if configured) and scan for errors from the relevant function. An error-free recent log window is required for GREEN.
- **Expo / mobile**: run the build check (`npx expo export` or the project's documented build command) — compile success is the gate; flag that on-device behavior still needs the user.
- **Obsidian plugin**: `npm run build` must pass + manifest.json valid JSON.
- **Web app**: if a playwright smoke test exists, run it.

When the real runtime is genuinely unreachable (physical device), end GREEN* with an explicit line: "compile/logs green — needs manual check on device: <exact steps>".

### 3. Report

End with a table:

```
| Check          | Result | Detail            |
|----------------|--------|-------------------|
| tsc --noEmit   | GREEN  |                   |
| pnpm test      | RED    | 2 failed: <names> |
```

- Any RED → verdict line: `GREENLIGHT: RED — not done.` Then fix-or-report per the session's task (if you made the edits, fix and re-run; if auditing, report only).
- All GREEN → verdict line: `GREENLIGHT: GREEN.`

## Rules

- Never claim done, fixed, or complete while any check is RED or unrun.
- Never skip a defined check because it "probably passes".
- Quote failing output verbatim (trimmed to the failing part).
- Don't fix unrelated pre-existing failures silently — report them as pre-existing, distinguish from regressions (check `git stash` / clean-tree run if ambiguous).

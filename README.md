# skills

Version-controlled agent skills, in Claude Code and Codex flavors.

## Layout

```
claude/   # skills for Claude Code (~/.claude/skills)
codex/    # skills for Codex CLI  (~/.codex/skills)
```

Each skill is a directory containing a `SKILL.md`.

| Skill | What it does |
|-------|--------------|
| `deliver` | End-to-end delivery workflow: implement, verify, hand off. |
| `greenlight` | Verification gate — runs the project's checks and blocks "done" claims until green. |
| `volley` | Cross-model review rally — the other model reviews, fixes applied, re-reviewed until approved. |

## Setup

Skills are used in place via symlinks from the agent skill directories into this repo:

```sh
for s in deliver greenlight volley; do
  ln -sfn "$PWD/claude/$s" ~/.claude/skills/$s
  ln -sfn "$PWD/codex/$s" ~/.codex/skills/$s
done
```

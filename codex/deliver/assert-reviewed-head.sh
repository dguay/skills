#!/usr/bin/env bash
set -u

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
  printf 'Usage: assert-reviewed-head.sh REVIEWED_HEAD CHECKPOINT\n' >&2
  exit 2
fi

reviewed_head=$1
checkpoint=$2
[[ "$reviewed_head" =~ ^[0-9a-fA-F]{7,64}$ ]] || {
  printf 'assert-reviewed-head: malformed reviewed HEAD: %s\n' "$reviewed_head" >&2
  exit 2
}

current_head=$(git rev-parse HEAD 2>/dev/null) || {
  printf 'assert-reviewed-head: not in a git worktree\n' >&2
  exit 2
}

if [[ "$current_head" != "$reviewed_head" ]]; then
  printf 'APPROVAL_INVALIDATED at %s: reviewed HEAD %s, current HEAD %s\n' \
    "$checkpoint" "$reviewed_head" "$current_head" >&2
  exit 1
fi

printf 'REVIEWED_HEAD_OK=%s checkpoint=%s\n' "$reviewed_head" "$checkpoint"

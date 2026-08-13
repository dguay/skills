#!/usr/bin/env bash
set -u

usage() {
  cat >&2 <<'EOF'
Usage:
  wait-review.sh prepare --sentinel PATH --result PATH
  wait-review.sh wait --sentinel PATH --result PATH --ledger PATH \
    --issue ISSUE --round N --reviewed-head SHA (--pid PID | --process-pattern PATTERN) \
    [--completion-claimed --started-at EPOCH --bound SECONDS --grace SECONDS]
  wait-review.sh --self-test
EOF
}

die() {
  printf 'wait-review: %s\n' "$*" >&2
  exit 2
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "missing value for $1"
}

safe_file_path() {
  local label=$1 path=$2
  [[ -n "$path" && "$path" != "/" && "$path" != "$HOME" && ! -d "$path" ]] ||
    die "unsafe $label path: $path"
}

append_ledger() {
  local verdict=$1
  printf '%s\t%s\treview_r%s_verdict\t%s\n' \
    "$(date +%s)" "$issue" "$round" "$verdict" >> "$ledger" ||
    die "could not append verdict to ledger: $ledger"
  if [[ "$verdict" != BLOCKED ]]; then
    printf '%s\t%s\treview_r%s_reviewed_head\t%s\n' \
      "$(date +%s)" "$issue" "$round" "$reviewed_head" >> "$ledger" ||
      die "could not append reviewed HEAD to ledger: $ledger"
  fi
}

process_is_alive() {
  local candidate command
  if [[ -n "$review_pid" ]]; then
    kill -0 "$review_pid" 2>/dev/null
    return
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$candidate" != "$$" && "$candidate" != "$PPID" ]] || continue
    command=$(ps -p "$candidate" -o command= 2>/dev/null || true)
    [[ "$command" == *wait-review.sh* ]] && continue
    return 0
  done < <(pgrep -f "$process_pattern" 2>/dev/null || true)
  return 1
}

wait_for_sentinel() {
  local seconds=$1 started now
  started=$(date +%s)
  while [[ ! -s "$sentinel" ]]; do
    now=$(date +%s)
    (( now - started < seconds )) || return 1
    sleep "$poll_seconds"
  done
}

record_blocked() {
  local reason=$1
  append_ledger BLOCKED
  printf 'BLOCKED: %s\n' "$reason" >&2
  return 1
}

parse_completion() {
  local exit_line exit_code session_id review_text last_line verdict

  exit_line=$(awk '/^REVIEW_EXIT=[0-9]+$/ {line=$0} END {print line}' "$sentinel" 2>/dev/null)
  [[ -n "$exit_line" ]] || {
    record_blocked "sentinel is missing a valid REVIEW_EXIT line: $sentinel"
    return 1
  }
  exit_code=${exit_line#REVIEW_EXIT=}
  printf '%s\n' "$exit_line"
  if [[ "$exit_code" != "0" ]]; then
    record_blocked "review process exited $exit_code"
    return 1
  fi

  [[ -s "$result" ]] || {
    record_blocked "result file is empty: $result"
    return 1
  }
  session_id=$(jq -er '.session_id | strings | select(length > 0)' "$result" 2>/dev/null) || {
    record_blocked "result file has no parseable session_id: $result"
    return 1
  }
  review_text=$(jq -er '.result | strings | select(length > 0)' "$result" 2>/dev/null) || {
    record_blocked "result file has no parseable review result: $result"
    return 1
  }
  last_line=$(printf '%s\n' "$review_text" | awk 'NF {line=$0} END {print line}')
  case "$last_line" in
    'VERDICT: APPROVED') verdict=APPROVED ;;
    'VERDICT: REVISE') verdict=REVISE ;;
    *)
      record_blocked "review result does not end with VERDICT: APPROVED or VERDICT: REVISE"
      return 1
      ;;
  esac

  append_ledger "$verdict"
  printf 'SESSION_ID=%s\nVERDICT=%s\nREVIEWED_HEAD=%s\n' \
    "$session_id" "$verdict" "$reviewed_head"
}

prepare() {
  local sentinel='' result=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sentinel) require_value "$@"; sentinel=$2; shift 2 ;;
      --result) require_value "$@"; result=$2; shift 2 ;;
      *) die "unknown prepare argument: $1" ;;
    esac
  done
  [[ -n "$sentinel" && -n "$result" ]] || die 'prepare requires --sentinel and --result'
  safe_file_path sentinel "$sentinel"
  safe_file_path result "$result"
  rm -f -- "$sentinel" "$result"
}

wait_review() {
  sentinel=''
  result=''
  ledger=''
  issue=''
  round=''
  reviewed_head=''
  review_pid=''
  process_pattern=''
  completion_claimed=0
  started_at=''
  bound=900
  grace=120
  poll_seconds=5
  local initial_wait=240 dead_recheck=30
  local now deadline remaining

  if [[ ${VOLLEY_SELF_TEST_MODE:-0} == 1 ]]; then
    poll_seconds=${VOLLEY_POLL_SECONDS:-0.05}
    initial_wait=${VOLLEY_WAITER_SECONDS:-2}
    dead_recheck=${VOLLEY_DEAD_RECHECK_SECONDS:-0.05}
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sentinel) require_value "$@"; sentinel=$2; shift 2 ;;
      --result) require_value "$@"; result=$2; shift 2 ;;
      --ledger) require_value "$@"; ledger=$2; shift 2 ;;
      --issue) require_value "$@"; issue=$2; shift 2 ;;
      --round) require_value "$@"; round=$2; shift 2 ;;
      --reviewed-head) require_value "$@"; reviewed_head=$2; shift 2 ;;
      --pid) require_value "$@"; review_pid=$2; shift 2 ;;
      --process-pattern) require_value "$@"; process_pattern=$2; shift 2 ;;
      --completion-claimed) completion_claimed=1; shift ;;
      --started-at) require_value "$@"; started_at=$2; shift 2 ;;
      --bound) require_value "$@"; bound=$2; shift 2 ;;
      --grace) require_value "$@"; grace=$2; shift 2 ;;
      *) die "unknown wait argument: $1" ;;
    esac
  done

  [[ -n "$sentinel" && -n "$result" && -n "$ledger" && -n "$issue" &&
     -n "$round" && -n "$reviewed_head" ]] || die 'wait is missing required arguments'
  [[ -n "$review_pid" || -n "$process_pattern" ]] || die 'wait requires --pid or --process-pattern'
  [[ -z "$review_pid" || -z "$process_pattern" ]] || die 'pass only one of --pid or --process-pattern'
  [[ "$round" =~ ^[1-9][0-9]*$ ]] || die '--round must be a positive integer'
  [[ "$reviewed_head" =~ ^[0-9a-fA-F]{7,64}$ ]] || die '--reviewed-head must be a git object id'
  [[ "$issue" != *$'\t'* && "$issue" != *$'\n'* ]] || die '--issue may not contain tabs or newlines'
  [[ "$bound" =~ ^[1-9][0-9]*$ && "$grace" =~ ^[0-9]+$ ]] || die 'bound/grace must be integer seconds'
  [[ -z "$review_pid" || "$review_pid" =~ ^[1-9][0-9]*$ ]] || die '--pid must be a positive integer'
  safe_file_path sentinel "$sentinel"
  safe_file_path result "$result"
  safe_file_path ledger "$ledger"
  [[ -d "$(dirname "$ledger")" ]] || die "ledger directory does not exist: $(dirname "$ledger")"

  if [[ -s "$sentinel" ]] || wait_for_sentinel "$initial_wait"; then
    parse_completion
    return
  fi

  if ! process_is_alive; then
    # A dead reviewer can win the race with its unconditional sentinel write.
    sleep "$dead_recheck"
    if [[ -s "$sentinel" ]]; then
      parse_completion
    else
      record_blocked "review process is dead and no sentinel appeared after ${dead_recheck}s"
    fi
    return
  fi

  if (( completion_claimed == 0 )); then
    printf 'STILL_RUNNING\n'
    return 0
  fi

  [[ "$started_at" =~ ^[0-9]+$ ]] || die '--completion-claimed requires --started-at EPOCH'
  deadline=$(( started_at + bound + grace ))
  now=$(date +%s)
  remaining=$(( deadline - now ))
  if (( remaining > 0 )) && wait_for_sentinel "$remaining"; then
    parse_completion
    return
  fi

  if process_is_alive; then
    printf 'STILL_RUNNING\n'
    return 0
  fi
  sleep "$dead_recheck"
  if [[ -s "$sentinel" ]]; then
    parse_completion
  else
    record_blocked "completion was claimed, but the reviewer is dead and no sentinel appeared"
  fi
}

self_test() {
  local test_dir script fake_head output sleeper status
  test_dir=$(mktemp -d "${TMPDIR:-/tmp}/wait-review-self-test.XXXXXX") || die 'mktemp failed'
  script=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  fake_head=0123456789abcdef0123456789abcdef01234567
  trap "rm -rf -- '$test_dir'" EXIT

  # A result file is intentionally 0 bytes until Claude exits; never inspect it mid-wait.
  printf '%s\n' '{"session_id":"session-1","result":"Looks good.\nVERDICT: APPROVED"}' > "$test_dir/result.json"
  : > "$test_dir/timeline.tsv"
  (sleep 0.2; printf 'REVIEW_EXIT=0\n' > "$test_dir/done") &
  sleeper=$!
  output=$(VOLLEY_SELF_TEST_MODE=1 VOLLEY_WAITER_SECONDS=2 VOLLEY_POLL_SECONDS=0.05 VOLLEY_DEAD_RECHECK_SECONDS=0.05 \
    "$script" wait --sentinel "$test_dir/done" --result "$test_dir/result.json" \
    --ledger "$test_dir/timeline.tsv" --issue 1 --round 1 --reviewed-head "$fake_head" --pid "$sleeper")
  wait "$sleeper" 2>/dev/null || true
  [[ "$output" == *'VERDICT=APPROVED'* ]] || die 'self-test: missed sentinel written mid-wait'

  # Short waiters caused nine-turn reviews; production waiter duration is fixed at a 240s floor.
  rm -f "$test_dir/done"
  (sleep 2) & sleeper=$!
  output=$(VOLLEY_SELF_TEST_MODE=1 VOLLEY_WAITER_SECONDS=1 VOLLEY_POLL_SECONDS=0.05 VOLLEY_DEAD_RECHECK_SECONDS=0.05 \
    "$script" wait --sentinel "$test_dir/done" --result "$test_dir/result.json" \
    --ledger "$test_dir/timeline.tsv" --issue 1 --round 2 --reviewed-head "$fake_head" --pid "$sleeper")
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  [[ "$output" == 'STILL_RUNNING' ]] || die 'self-test: live timeout did not yield STILL_RUNNING'

  # Harness completion without a sentinel was observed six minutes before the real review exit.
  set +e
  output=$(VOLLEY_SELF_TEST_MODE=1 VOLLEY_WAITER_SECONDS=1 VOLLEY_POLL_SECONDS=0.05 VOLLEY_DEAD_RECHECK_SECONDS=0.05 \
    "$script" wait --sentinel "$test_dir/done" --result "$test_dir/result.json" \
    --ledger "$test_dir/timeline.tsv" --issue 1 --round 3 --reviewed-head "$fake_head" --pid 999999 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *'review process is dead and no sentinel appeared'* ]] ||
    die 'self-test: dead-without-sentinel was not distinguished from a real exit'

  printf 'REVIEW_EXIT=0\n' > "$test_dir/done"
  : > "$test_dir/result.json"
  set +e
  output=$(VOLLEY_SELF_TEST_MODE=1 VOLLEY_WAITER_SECONDS=1 VOLLEY_POLL_SECONDS=0.05 VOLLEY_DEAD_RECHECK_SECONDS=0.05 \
    "$script" wait --sentinel "$test_dir/done" --result "$test_dir/result.json" \
    --ledger "$test_dir/timeline.tsv" --issue 1 --round 4 --reviewed-head "$fake_head" --pid 999999 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 && "$output" == *'result file is empty'* ]] ||
    die 'self-test: zero-byte result was accepted'

  printf 'wait-review self-test: PASS\n'
}

[[ $# -gt 0 ]] || { usage; exit 2; }
case "$1" in
  prepare) shift; prepare "$@" ;;
  wait) shift; wait_review "$@" ;;
  --self-test) [[ $# -eq 1 ]] || die '--self-test takes no arguments'; self_test ;;
  -h|--help) usage; exit 0 ;;
  *) usage; die "unknown command: $1" ;;
esac

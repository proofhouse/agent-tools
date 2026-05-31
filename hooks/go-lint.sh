#!/usr/bin/env bash
# Lint gate for Claude Code, driven by the project's `just` recipes:
#   - Go:       `just fix-go`       (go fix x2, golangci-lint fmt + run --fix)
#   - Prose:    `just lint-prose`   (vale; Markdown and Go comments)
#   - Spelling: `just lint-spelling` (cspell; tree-wide, self-filtering)
#
# Two diff-driven, synchronous blocking points:
#
#   PostToolBatch -- once per batch of tool calls (a lone call still counts as
#                    a batch), mid-turn. Lints the whole module when *.go or
#                    .golangci.yml changed vs HEAD; vale/cspell run over the
#                    changed files. A shared content fingerprint skips the
#                    cold lint when nothing changed since the last run, so
#                    read-only batches cost nothing.
#
#   Stop          -- when the agent tries to finish: the same lint as the hard
#                    yield gate. When the tree is clean and Go *production*
#                    code changed, it blocks ONCE per change-set with a
#                    reminder checklist (tests, mutation, full lint).
#
# Verified against the installed claude (see AGENTS.md): PostToolBatch fires
# even for a single-call turn and blocks reliably. PostToolUse is unused --
# it fires per individual call, so it re-lints redundantly across a parallel
# batch; PostToolBatch collapses that to one run and defers intra-batch
# intermediate states. Stop may not carry hookSpecificOutput, so blocks use
# only top-level decision/reason (see emit_block).
#
# fix-go mutates files (formatting, autofixes); every run that touches Go
# tells the agent to re-read those files before its next write.
#
# Toolchain failures (no container runtime, missing tool) never block: they
# surface as a systemMessage so a broken toolchain can't trap the agent.
#
# Registered locally via .claude/settings.local.json (not committed).
set -euo pipefail

# --- output (each exits) ---------------------------------------------------

emit_block() {
  # decision/reason/systemMessage are valid on both PostToolUse and Stop.
  # hookSpecificOutput is NOT a valid field on Stop, so it is omitted -- a
  # Stop block carrying it gets rejected by output validation and fails OPEN.
  # shellcheck disable=SC2016  # $reason/$msg are jq variables, set via --arg
  jq -n --arg reason "$1" --arg msg "$2" \
    '{decision: "block", reason: $reason, systemMessage: $msg, suppressOutput: true}'
  exit 0
}

emit_context() {
  # shellcheck disable=SC2016  # $ctx/$event are jq variables, set via --arg
  jq -n --arg ctx "$1" --arg event "$event" \
    '{suppressOutput: true, hookSpecificOutput: {hookEventName: $event, additionalContext: $ctx}}'
  exit 0
}

emit_skip() {
  # shellcheck disable=SC2016  # $msg is a jq variable, set via --arg
  jq -n --arg msg "$1" '{suppressOutput: true, systemMessage: $msg}'
  exit 0
}

# --- linter runner ---------------------------------------------------------

# Run a command, capturing stdout (findings) / stderr (tool chatter) / rc.
run_recipe() {
  if RUN_STDOUT=$("$@" 2>"$err_file"); then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
  RUN_STDERR=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
}

# Toolchain trouble (not real findings) -> skip rather than trap the agent.
# Matches a lowercased copy (no `grep -q`, which can SIGPIPE under pipefail).
is_infra_failure() {
  local blob
  blob=$(printf '%s\n%s' "$1" "$2" | tr '[:upper:]' '[:lower:]')
  case "$blob" in
  *"cannot connect to the docker daemon"* | *"is the docker daemon running"* | \
    *"error during connect"* | *"command not found"* | *"does not contain recipe"* | \
    *"cannot find binary path"* | *"executable file not found"* | \
    *"permission denied while trying to connect"*) return 0 ;;
  *) return 1 ;;
  esac
}

# Distill linter output ($1 stdout, $2 stderr) into findings: strip ANSI, drop
# just's echoed commands and golangci runner chatter, bound the size. Prefer
# stdout; fall back to stderr.
findings_text() {
  local src=$1 esc
  [[ -z ${1//[[:space:]]/} ]] && src=$2
  esc=$(printf '\033')
  printf '%s\n' "$src" |
    sed -E "s/${esc}\[[0-9;]*[A-Za-z]//g" |
    awk '
      /^level=(warning|info|debug) / { next }
      /^error: Recipe .* failed on line / { next }
      /^go (fix|vet|build|tool) / { next }
      /^(vale|cspell) / { next }
      /^DOCKER_CONFIG=/ { next }
      { sub(/[ \t\r]+$/, ""); buf[++n] = $0 }
      END {
        for (i = 1; i <= n && i <= 120; i++) print buf[i]
        if (n > 120) printf "... (%d more lines)\n", n - 120
      }
    '
}

# Run one linter and fold any findings into FINDINGS / FAILED. A toolchain
# failure aborts the whole hook (non-blocking skip). $1 = label, rest = command.
lint_with() {
  local label=$1
  shift
  run_recipe "$@"
  is_infra_failure "$RUN_STDOUT" "$RUN_STDERR" &&
    emit_skip "Lint hook skipped: ${label} could not run (toolchain unavailable)."
  if [[ $RUN_RC -ne 0 ]]; then
    FAILED=1
    FINDINGS+="
### ${label}
$(findings_text "$RUN_STDOUT" "$RUN_STDERR")
"
  fi
}

# --- git / cache helpers ---------------------------------------------------

# All non-vendor files that differ from HEAD: tracked edits + brand-new files.
compute_changed() {
  {
    git diff --name-only HEAD -- . ':(exclude)vendor'
    git ls-files --others --exclude-standard -- . ':(exclude)vendor'
  } | sort -u
}

# Hash the content (name + bytes) of the newline-separated file list in $1.
compute_fingerprint() {
  {
    while IFS= read -r f; do
      if [[ -f $f ]]; then
        printf '%s\n' "$f"
        cat -- "$f"
      fi
    done <<<"$1" | shasum -a 256 | cut -d' ' -f1
  } || true
}

# Cache the last Stop outcome (fingerprint + rc + block payload).
write_state() {
  [[ -z $fingerprint ]] && return 0
  # shellcheck disable=SC2016  # $fp/$rc/$reason/$msg are jq variables, set via --arg(json)
  jq -n --arg fp "$fingerprint" --argjson rc "$1" --arg reason "$2" --arg msg "$3" \
    '{fingerprint: $fp, rc: $rc, reason: $reason, systemMessage: $msg}' >"$state_file" 2>/dev/null || true
}

# A re-read nudge listing the still-present files from $1 (newline-separated).
reread_note() {
  local list
  list=$(while IFS= read -r f; do [[ -f $f ]] && printf -- '- %s\n' "$f"; done <<<"$1")
  # shellcheck disable=SC2016  # backticks are literal markdown for the agent, not command substitution
  printf '`just fix-go` may have reformatted or autofixed these files. Re-read them before your next Edit/Write so a stale cached copy does not fail the write:\n%s' "$list"
}

# Subset of a newline list ($2) whose entries match ERE $1.
grep_files() { printf '%s\n' "$2" | grep -E "$1" || true; }

# --- main ------------------------------------------------------------------

input=$(cat)
event=$(jq -r '.hook_event_name // "Stop"' <<<"$input")
session_id=$(jq -r '.session_id // "default"' <<<"$input")
session_id=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')

project_dir=${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // "."' <<<"$input")}
cd "$project_dir" || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git rev-parse --verify -q HEAD >/dev/null || exit 0

state_dir="tmp/claude-go-hook"
mkdir -p "$state_dir"
err_file="${state_dir}/${session_id}.err"

if ! command -v just >/dev/null 2>&1; then
  emit_skip "Lint hook skipped: \`just\` is not installed."
fi

FINDINGS=""
FAILED=0

case "$event" in
PostToolBatch | Stop)
  # Diff-driven whole-module gate. PostToolBatch runs once per batch (mid-turn);
  # Stop runs at the yield boundary. A shared content fingerprint means an
  # unchanged tree is linted once, not re-linted per event or read-only batch.
  changed=$(compute_changed)
  [[ -z $changed ]] && exit 0
  fingerprint=$(compute_fingerprint "$changed")
  state_file="${state_dir}/${session_id}.state"

  note=""
  cached=0
  if [[ -n $fingerprint && -f $state_file ]]; then
    cached_fp=$(jq -r '.fingerprint // ""' "$state_file" 2>/dev/null || true)
    if [[ $cached_fp == "$fingerprint" ]]; then
      cached_rc=$(jq -r '.rc // 0' "$state_file" 2>/dev/null || echo 0)
      if [[ $cached_rc != 0 ]]; then
        # Tree still failing, unchanged since the last lint.
        [[ $event == Stop ]] && emit_block "$(jq -r '.reason // ""' "$state_file")" "$(jq -r '.systemMessage // ""' "$state_file")"
        exit 0 # PostToolBatch: don't re-nag mid-turn
      fi
      cached=1 # cached clean: skip the lint, fall through to clean handling
    fi
  fi

  if [[ $cached -eq 0 ]]; then
    go_changed=$(grep_files '\.go$' "$changed")
    golangci_changed=$(grep_files '(^|/)\.golangci\.yml$' "$changed")
    prose_changed=$(grep_files '\.(md|go)$' "$changed")
    ran_fixgo=0
    if [[ -n $go_changed || -n $golangci_changed ]]; then
      lint_with "Go -- just fix-go (whole module)" just fix-go
      ran_fixgo=1
    fi
    if [[ -n $prose_changed ]]; then
      prose_args=()
      while IFS= read -r f; do [[ -n $f ]] && prose_args+=("$f"); done <<<"$prose_changed"
      lint_with "Prose -- just lint-prose" just lint-prose "${prose_args[@]}"
    fi
    spell_args=()
    while IFS= read -r f; do [[ -n $f ]] && spell_args+=("$f"); done <<<"$changed"
    lint_with "Spelling -- just lint-spelling" just lint-spelling "${spell_args[@]}"

    # fix-go mutates files; re-derive the changed set / fingerprint from the
    # post-fix tree -- the state the next event sees and the cache key.
    changed=$(compute_changed)
    fingerprint=$(compute_fingerprint "$changed")
    [[ $ran_fixgo -eq 1 ]] && note=$(reread_note "$changed")

    if [[ $FAILED -eq 1 ]]; then
      reason=$(printf 'Lint gate failed -- fix every issue below before continuing, then let the hook re-run:\n%s\n%s' "$FINDINGS" "$note")
      sysmsg="Lint gate: findings need fixing before finishing."
      write_state 1 "$reason" "$sysmsg"
      emit_block "$reason" "$sysmsg"
    fi
    write_state 0 "" ""
  fi

  # --- clean (fresh or cached) ---
  if [[ $event == Stop ]]; then
    # Reminder checklist, blocking once per change-set, when Go production code
    # changed. A separate marker (not the lint cache) keeps a clean PostToolBatch
    # from suppressing it.
    prod_go_changed=$(printf '%s\n' "$changed" | grep -E '\.go$' | grep -vE '_test\.go$' || true)
    if [[ -n $prod_go_changed ]]; then
      remind_file="${state_dir}/${session_id}.reminded"
      if [[ "$(cat "$remind_file" 2>/dev/null || true)" != "$fingerprint" ]]; then
        printf '%s' "$fingerprint" >"$remind_file"
        targets=$(while IFS= read -r f; do [[ -n $f ]] && printf './%s\n' "$(dirname "$f")"; done <<<"$prod_go_changed" | sort -u)
        # shellcheck disable=SC2016  # backticks are literal markdown for the agent, not command substitution
        reason=$(printf 'Lint is clean. Before you finish, a checklist for the Go code you changed (fires once per change-set):\n\n- [ ] Tests: did you add or adjust tests for the change, and does `just cover` still meet the coverage gate?\n- [ ] Mutation tests: run `just mutate <pkg>` (gremlins) on the changed packages and resolve any SURVIVED / NOT COVERED mutants:\n%s\n- [ ] Whole-program gates (not run by fix-go): `just lint-go-deadcode` and `just lint-go-arch`, if you changed exported surface or package wiring.\n- [ ] Full sweep: `just lint` before considering it done (covers the markdown, yaml, config, arch, deadcode, and modernize gates this hook does not run).' "$targets")
        emit_block "$reason" "Reminder: tests / mutation / full lint for the changed Go code?"
      fi
    fi
    exit 0 # Stop cannot carry additionalContext
  fi

  # PostToolBatch clean: surface the re-read nudge (additionalContext valid here).
  [[ -n $note ]] && emit_context "$note"
  exit 0
  ;;

*)
  # Any other event (e.g. PostToolUse, if registered): no-op.
  exit 0
  ;;
esac

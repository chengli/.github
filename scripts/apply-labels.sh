#!/usr/bin/env bash
# apply-labels.sh — apply inferred labels to a GitHub issue with
# strict only-ADD semantics.
#
# Reads existing labels on the issue and only adds label categories
# (phase:* / complexity:* / type:*) that are NOT already present. If
# the author already wrote `complexity:simple`, this script will not
# overwrite it with `complexity:standard` even if the heuristic/LLM
# proposed standard. This preserves author intent and dodges
# label ping-pong with manual edits.
#
# Inputs (env):
#   REPO          — owner/repo (e.g. chengli/agent-workflow-test)
#   ISSUE         — issue number
#   PROPOSE_PHASE — proposed phase label, e.g. phase:think (may be empty)
#   PROPOSE_COMPLEXITY — proposed complexity label (may be empty)
#   PROPOSE_TYPE  — proposed type label (may be empty)
#   GH_TOKEN      — auth for `gh` (must have `issues: write`)
#   DRY_RUN       — if set to "1", print actions without executing.
#
# Output: one JSON line summarizing applied / skipped labels (for the
# workflow run summary).

set -euo pipefail

: "${REPO:?REPO required}"
: "${ISSUE:?ISSUE required}"
PROPOSE_PHASE="${PROPOSE_PHASE:-}"
PROPOSE_COMPLEXITY="${PROPOSE_COMPLEXITY:-}"
PROPOSE_TYPE="${PROPOSE_TYPE:-}"
DRY_RUN="${DRY_RUN:-0}"

# 1. Read existing labels via gh.
existing_json=$(gh issue view "$ISSUE" --repo "$REPO" --json labels --jq '[.labels[].name]')

has_prefix_category() {
  # $1 = namespace prefix (e.g. "phase:")
  local prefix="$1"
  printf '%s' "$existing_json" | jq -e --arg p "$prefix" 'any(.[]; startswith($p))' >/dev/null
}

has_type_category() {
  # Type category is unprefixed (bug / enhancement / documentation).
  # Match against the closed set so we don't false-positive on
  # unrelated unprefixed labels (e.g. "good first issue", "wontfix").
  printf '%s' "$existing_json" \
    | jq -e 'any(.[]; . == "bug" or . == "enhancement" or . == "documentation")' >/dev/null
}

to_add=()
skipped=()

maybe_add_prefix() {
  # $1 = proposed label (e.g. phase:think); $2 = namespace prefix
  local label="$1" prefix="$2"
  if [[ -z "$label" ]]; then
    return
  fi
  if has_prefix_category "$prefix"; then
    skipped+=("$prefix(already present)")
  else
    to_add+=("$label")
  fi
}

maybe_add_type() {
  # $1 = proposed type label (bug / enhancement / documentation)
  local label="$1"
  if [[ -z "$label" ]]; then
    return
  fi
  if has_type_category; then
    skipped+=("type(already present)")
  else
    to_add+=("$label")
  fi
}

maybe_add_prefix "$PROPOSE_PHASE" "phase:"
maybe_add_prefix "$PROPOSE_COMPLEXITY" "complexity:"
maybe_add_type "$PROPOSE_TYPE"

if [[ "${#to_add[@]}" -eq 0 ]]; then
  echo "{\"action\":\"noop\",\"existing\":$existing_json,\"skipped\":$(printf '%s\n' "${skipped[@]}" | jq -R . | jq -s .)}"
  exit 0
fi

# 2. Apply via gh. We use --add-label which is purely additive and
#    leaves existing labels alone (gh CLI behavior).
add_args=()
for l in "${to_add[@]}"; do
  add_args+=(--add-label "$l")
done

if [[ "$DRY_RUN" == "1" ]]; then
  printf '[dry-run] gh issue edit %s --repo %s' "$ISSUE" "$REPO" >&2
  for a in "${add_args[@]}"; do printf ' %q' "$a" >&2; done
  printf '\n' >&2
else
  gh issue edit "$ISSUE" --repo "$REPO" "${add_args[@]}" >&2
fi

added_json=$(printf '%s\n' "${to_add[@]}" | jq -R . | jq -s .)
skipped_json=$(printf '%s\n' "${skipped[@]:-}" | jq -R . | jq -s 'map(select(length>0))')
echo "{\"action\":\"added\",\"added\":$added_json,\"skipped\":$skipped_json,\"existing\":$existing_json}"

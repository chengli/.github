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

# Helper: serialize a bash array to a JSON array. Handles the empty
# case explicitly because `printf '%s\n' "${arr[@]:-}"` emits an empty
# line in bash, which jq -s would turn into `[""]`.
arr_to_json() {
  local -n _arr=$1
  if [[ "${#_arr[@]}" -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${_arr[@]}" | jq -R . | jq -s .
  fi
}

if [[ "${#to_add[@]}" -eq 0 ]]; then
  printf '{"action":"noop","existing":%s,"skipped":%s}\n' \
    "$existing_json" "$(arr_to_json skipped)"
  exit 0
fi

# 2. Apply via gh, ONE LABEL AT A TIME so that a missing label on the
#    repo doesn't fail the whole batch (and the workflow). The dispatcher
#    creates phase:* and complexity:* labels by convention, but this
#    workflow is the safety net for repos that haven't been bootstrapped
#    yet — be tolerant.
added=()
not_found=()

apply_one() {
  local label="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] gh issue edit %s --repo %s --add-label %q\n' "$ISSUE" "$REPO" "$label" >&2
    added+=("$label")
    return
  fi
  local err
  if err=$(gh issue edit "$ISSUE" --repo "$REPO" --add-label "$label" 2>&1 >/dev/null); then
    added+=("$label")
  else
    # gh prints "could not add label: <name> not found" on missing labels.
    if printf '%s' "$err" | grep -qiE 'not found|could not add label'; then
      echo "::warning::label '$label' does not exist on $REPO — skipping (run \`gh label create $label\` to enable)" >&2
      not_found+=("$label")
    else
      # Other failures (rate limit, auth) — re-raise.
      printf '%s\n' "$err" >&2
      return 1
    fi
  fi
}

for l in "${to_add[@]}"; do
  apply_one "$l"
done

printf '{"action":"applied","added":%s,"not_found":%s,"skipped":%s,"existing":%s}\n' \
  "$(arr_to_json added)" \
  "$(arr_to_json not_found)" \
  "$(arr_to_json skipped)" \
  "$existing_json"

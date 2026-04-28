#!/usr/bin/env bash
# heuristic.sh — pure-deterministic label inference from issue title.
#
# Encodes rules from agent-workflow-v2/config/phases.yaml lines 53-58
# verbatim (do not invent new rules without updating phases.yaml first):
#
#   "Default complexity is standard; use simple only for doc fixes,
#    renames, or single-file under-50 LOC changes. Use bug instead of
#    enhancement when the title starts with fix: (or bugfix: / hotfix:);
#    use documentation when the title starts with docs: or doc:.
#    Scoped forms like fix(api): also map to bug."
#
# Phase default (phase:think) follows the /github-spec convention.
#
# Inputs: TITLE env var (issue title, conventional-commits-style prefix
#         expected but not required).
# Outputs (to $GITHUB_OUTPUT or stdout in `key=value` form):
#   add_phase=phase:think|<empty>
#   add_complexity=complexity:simple|complexity:standard|<empty>
#   add_type=bug|documentation|enhancement|<empty>
#   need_llm=true|false  — true if any of the three above is empty after
#                          heuristic runs (the LLM should fill the gaps).
#
# NOTE on type label format: the project uses GitHub's UNPREFIXED
# default labels (`bug`, `enhancement`, `documentation`) for the type
# category, not `type:*` namespaced labels. phases.yaml lines 51-58
# write these without prefix (`--label enhancement`). Phase and
# complexity ARE namespaced (`phase:*`, `complexity:*`).
#
# Notes:
#   - Title-prefix matching is case-sensitive (conventional commits are
#     lowercase). Scoped form `fix(api):` matches via regex.
#   - This script ONLY proposes labels. Combining with existing labels
#     (only-add semantics) is `apply-labels.sh`'s job.

set -euo pipefail

TITLE="${TITLE:-}"

# Strip any leading whitespace
TITLE_TRIMMED="${TITLE#"${TITLE%%[![:space:]]*}"}"

phase=""
complexity=""
type=""

# Type detection — title prefix
# Accept: prefix:, prefix(scope):
# fix / bugfix / hotfix → bug
# docs / doc → documentation
# else → enhancement (default)
# (Regex stored in variables to dodge bash 3.2 quoting quirks.)
re_bug='^(fix|bugfix|hotfix)(\([^)]+\))?:'
re_docs='^(docs|doc)(\([^)]+\))?:'
if [[ "$TITLE_TRIMMED" =~ $re_bug ]]; then
  type="bug"
elif [[ "$TITLE_TRIMMED" =~ $re_docs ]]; then
  type="documentation"
  # phases.yaml: "use simple only for doc fixes, renames, or single-file
  # under-50 LOC changes" — doc fixes qualify; mark complexity simple.
  complexity="complexity:simple"
fi

# Phase default: phase:think (per /github-spec convention)
phase="phase:think"

# Complexity default: standard, unless heuristic-narrowed above
if [[ -z "$complexity" ]]; then
  # We do NOT default complexity here because phases.yaml says simple is
  # *also* valid for "renames, or single-file under-50 LOC changes" —
  # neither of which we can detect from title alone. Leave empty so the
  # LLM (or final fallback) chooses standard vs simple based on body.
  complexity=""
fi

# If type still empty (no fix/docs prefix), heuristic alone yields
# enhancement. But edge cases (feature requests with non-standard
# prefixes, e.g. "feat:", "refactor:") may want LLM input on whether
# they're truly enhancement vs something else. Per phases.yaml the
# DEFAULT is enhancement, so we set it as a safe fallback only if the
# LLM step fails.
if [[ -z "$type" ]]; then
  # Conservative: don't decide here, let LLM weigh in.
  type=""
fi

# Decide whether LLM is needed
need_llm="false"
if [[ -z "$phase" || -z "$complexity" || -z "$type" ]]; then
  need_llm="true"
fi

# Emit outputs
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "add_phase=$phase"
    echo "add_complexity=$complexity"
    echo "add_type=$type"
    echo "need_llm=$need_llm"
  } >> "$GITHUB_OUTPUT"
fi

# Always echo to stdout for local testing
cat <<EOF
add_phase=$phase
add_complexity=$complexity
add_type=$type
need_llm=$need_llm
EOF

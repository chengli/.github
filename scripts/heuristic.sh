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
#   - Title-prefix matching is CASE-INSENSITIVE: "Fix:" and "FIX:" match
#     too. Real-world authors mix title-case despite conventional-commits
#     preference for lowercase. Scoped form `fix(api):` matches via regex.
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
# else → undecided (LLM will weigh in)
# Case-insensitive match — see note in module header.
# (Regex stored in variables to dodge bash 3.2 quoting quirks.)
shopt -s nocasematch
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
shopt -u nocasematch

# Phase default: phase:think (per /github-spec convention)
phase="phase:think"

# Complexity is intentionally left empty when not narrowed by the docs
# rule above — phases.yaml says simple is also valid for renames or
# single-file under-50-LOC changes, neither of which we can detect from
# title alone. The LLM (or final hardcoded fallback) chooses standard vs
# simple based on body content.

# Decide whether LLM is needed. Phase is always set above, so this is
# effectively (complexity-empty OR type-empty); listed in full for
# clarity and to keep the contract explicit.
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

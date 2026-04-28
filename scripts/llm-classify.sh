#!/usr/bin/env bash
# llm-classify.sh — LLM-backed label classifier for issue grooming.
#
# Runs Claude (via the `claude` CLI) in non-interactive mode and asks
# for a strict JSON classification of an unlabeled issue. Only invoked
# when the deterministic heuristic could not fill all three required
# label categories (phase / complexity / type).
#
# Inputs (env):
#   TITLE          — issue title
#   BODY           — issue body (may be empty)
#   MODEL          — Claude model id (default: claude-sonnet-4-6)
#   CLAUDE_HOME    — directory to seed with .credentials.json before
#                    invoking the CLI (default: $HOME/.claude)
#   CREDENTIALS_FILE — path to a file containing the full Claude auth
#                    JSON blob (.claudeAiOauth.{accessToken,refreshToken,
#                    expiresAt}). Pulled from AWS SM
#                    (agent-workflow-v2/claude-auth-token) by an earlier
#                    workflow step. Reading from a file path keeps the
#                    blob out of GITHUB_OUTPUT/log streams.
#
# Output (stdout):
#   key=value lines, suitable for `>> $GITHUB_OUTPUT`:
#     llm_phase=phase:think         (always phase:think — current convention)
#     llm_complexity=complexity:simple|complexity:standard|complexity:complex
#     llm_type=bug|enhancement|documentation     (UNPREFIXED — project uses
#                                                  GitHub default labels
#                                                  for the type category)
#     llm_status=ok|fail
#
# Failure mode: on any error (CLI install fail, OAuth expired, JSON
# parse fail, etc.), emit `llm_status=fail` and use safe defaults
# (phase:think / complexity:standard / type:enhancement). Never block
# the workflow — issue creation must always succeed.

set -uo pipefail

TITLE="${TITLE:-}"
BODY="${BODY:-}"
MODEL="${MODEL:-claude-sonnet-4-6}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-}"

# Safe-default fallback emitter — used on any failure path.
emit_fallback() {
  local reason="$1"
  echo "llm_phase=phase:think"
  echo "llm_complexity=complexity:standard"
  echo "llm_type=enhancement"
  echo "llm_status=fail"
  echo "llm_reason=$reason" >&2
}

if [[ -z "$CREDENTIALS_FILE" || ! -s "$CREDENTIALS_FILE" ]]; then
  emit_fallback "no/empty CREDENTIALS_FILE"
  exit 0
fi

# 1. Seed credentials so the CLI picks them up via its standard auth path.
mkdir -p "$CLAUDE_HOME"
chmod 700 "$CLAUDE_HOME"
cp "$CREDENTIALS_FILE" "$CLAUDE_HOME/.credentials.json"
chmod 600 "$CLAUDE_HOME/.credentials.json"

# 2. Build the prompt. Strict — must return one JSON object, nothing else.
prompt=$(cat <<EOF
Classify this GitHub issue into three labels. Output ONE JSON object,
nothing else, no prose, no markdown fences.

Schema (all three keys REQUIRED):
{
  "phase": "phase:think",
  "complexity": "complexity:simple" | "complexity:standard" | "complexity:complex",
  "type": "bug" | "enhancement" | "documentation"
}

Note on type: it is UNPREFIXED (just "bug", not "type:bug") because
the project uses GitHub's default labels for the type category.

Rules (verbatim from the dispatcher heuristic):
- Default phase is phase:think.
- Default complexity is complexity:standard. Use complexity:simple ONLY for
  doc fixes, renames, or single-file under-50 LOC changes.
- Use complexity:complex only for cross-cutting / multi-file / risky changes.
- Type defaults to enhancement. Use bug if title starts with
  fix:, bugfix:, or hotfix: (incl. scoped forms like fix(api):). Use
  documentation if title starts with docs: or doc:.

Issue title:
$TITLE

Issue body:
$BODY
EOF
)

# 3. Invoke claude CLI. Use --output-format=json so we get a structured
#    envelope; the actual classification JSON lives in .result.
#    Bound runtime hard: --max-turns 1 (single completion, no tool use).

if ! command -v claude >/dev/null 2>&1; then
  # Try npx fallback (downloads on first run; cached after).
  if ! command -v npx >/dev/null 2>&1; then
    emit_fallback "neither claude nor npx in PATH"
    exit 0
  fi
  CLAUDE_CMD=(npx --yes -p @anthropic-ai/claude-code claude)
else
  CLAUDE_CMD=(claude)
fi

raw_output=$("${CLAUDE_CMD[@]}" \
  --print \
  --model "$MODEL" \
  --max-turns 1 \
  --output-format json \
  --permission-mode bypassPermissions \
  <<<"$prompt" 2>/tmp/claude-stderr) || {
    emit_fallback "claude CLI exited non-zero ($(head -c 200 /tmp/claude-stderr 2>/dev/null))"
    exit 0
  }

# 4. Extract the inner JSON. claude --output-format=json wraps the
#    answer in {"result": "...", ...}. Pull .result then re-parse.
inner=$(printf '%s' "$raw_output" | jq -r '.result // empty' 2>/dev/null) || inner=""
if [[ -z "$inner" ]]; then
  emit_fallback "empty .result from claude"
  exit 0
fi

# Strip optional markdown fences if model emitted them despite the
# instruction.
inner_clean=$(printf '%s' "$inner" | sed -E 's/^```(json)?//; s/```$//' | tr -d '\r')

phase=$(printf '%s' "$inner_clean" | jq -r '.phase // empty' 2>/dev/null) || phase=""
complexity=$(printf '%s' "$inner_clean" | jq -r '.complexity // empty' 2>/dev/null) || complexity=""
type=$(printf '%s' "$inner_clean" | jq -r '.type // empty' 2>/dev/null) || type=""

# Whitelist validation — guard against hallucinated label values.
case "$phase" in
  phase:think) ;;
  *) phase="phase:think" ;;
esac
case "$complexity" in
  complexity:simple|complexity:standard|complexity:complex) ;;
  *) complexity="complexity:standard" ;;
esac
case "$type" in
  bug|enhancement|documentation) ;;
  *) type="enhancement" ;;
esac

echo "llm_phase=$phase"
echo "llm_complexity=$complexity"
echo "llm_type=$type"
echo "llm_status=ok"

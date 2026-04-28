# chengli/.github — shared workflows

Org-level "magic" repo. Workflows under `.github/workflows/` are
reusable from any other repo under `chengli/`.

## Workflows

### `auto-groom-issue.yml`

Auto-applies the three label categories the v3 dispatcher requires
(`phase:* + complexity:* + type`) to newly-opened issues. Heuristic-
first, LLM-fallback (Claude Sonnet 4.6 via OAuth from AWS Secrets
Manager). Only ADDs missing categories — never removes or modifies
existing labels.

Note: the type category uses GitHub's UNPREFIXED default labels
(`bug`, `enhancement`, `documentation`) per the project's actual
convention in `agent-workflow-v2/config/phases.yaml` lines 51-58.
Phase and complexity ARE namespaced (`phase:*`, `complexity:*`).

Caller pattern (drop into a fleet repo's `.github/workflows/groom.yml`):

```yaml
name: Auto-groom new issues
on:
  issues:
    types: [opened]
jobs:
  groom:
    uses: chengli/.github/.github/workflows/auto-groom-issue.yml@v1
    with:
      aws_role_arn: arn:aws:iam::740838937338:role/agent-workflow-gh-actions-groomer
    permissions:
      issues: write
      id-token: write
      contents: read
```

Heuristic rules live in `scripts/heuristic.sh` and mirror
`agent-workflow-v2/config/phases.yaml` lines 53-58 verbatim.

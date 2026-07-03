[![FivexL](https://releases.fivexl.io/like-this-repo-banner.png)](https://fivexl.io/#email-subscription)

### Want practical AWS infrastructure insights?

👉 [Subscribe to our newsletter](https://fivexl.io/#email-subscription) to get:

- Real stories from real AWS projects  
- No-nonsense DevOps tactics  
- Cost, security & compliance patterns that actually work  
- Expert guidance from engineers in the field

=========================================================================

# shared-workflows

FivexL's collection of reusable GitHub Actions workflows.

| Workflow | Purpose |
|---|---|
| [`ai-code-review`](.github/workflows/ai-code-review.yml) | AI-powered pull-request review with OpenCode on Amazon Bedrock |

## ai-code-review

### What it does

On every pull-request push, an AI reviewer:

- reads the PR diff and picks 2–3 review dimensions that fit the change —
  business logic, security, performance, or a more fitting one such as
  infrastructure-as-code or documentation alignment;
- runs a focused review subagent per dimension, guided by the repository's own
  rules files (`AGENTS.md`, `CLAUDE.md`, `.claude/rules/*.md`, per-directory
  `AGENTS.md`);
- posts findings as inline review comments (capped, default 10) and maintains
  a single summary comment per PR;
- keeps threads tidy across pushes: resolves threads whose issue left the
  diff, never re-litigates a finding a human dismissed ("false positive",
  "intended", "won't fix"), and never touches comments left by other
  automation;
- filters hard for severity: production bugs, data loss, security issues,
  user-measurable performance regressions, or explicit violations of the
  repo's stated rules. Style nits are dropped — when in doubt, it stays
  silent.

The reviewer never approves or blocks a PR — humans approve. It runs on the
[OpenCode](https://opencode.ai) CLI with Amazon Bedrock models, authenticated
via a GitHub App (comments) and AWS OIDC (models). No long-lived API keys are
stored anywhere.

### Intended use

- **FivexL repositories** call the reusable workflow in this repo directly
  via the caller template below.
- **Other organizations**: copy
  [`.github/workflows/ai-code-review.yml`](.github/workflows/ai-code-review.yml)
  into your own org's shared-workflows repository and adopt the same caller
  pattern. The workflow is deliberately self-contained — one YAML file, all
  logic embedded — precisely so that this copy is trivial and you are not
  coupled to this repo's `main` branch.

### Adoption (per repository)

Copy [`workflow-templates/ai-review-caller.yml`](workflow-templates/ai-review-caller.yml)
to the repo as `.github/workflows/ai-review.yml`. The essential part:

```yaml
jobs:
  review:
    if: >-
      !github.event.pull_request.draft &&
      github.event.pull_request.head.repo.full_name == github.repository
    uses: fivexl/shared-workflows/.github/workflows/ai-code-review.yml@main
    secrets:
      APP_ID: ${{ secrets.APP_ID }}
      APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
      BEDROCK_ROLE_ARN: ${{ secrets.DEVELOPMENT_ACCOUNT_ROLE_ARN }}
```

`BEDROCK_ROLE_ARN` is the workflow's secret interface — map it from whatever
org secret holds your role ARN (at FivexL: `DEVELOPMENT_ACCOUNT_ROLE_ARN`).

Optional workflow inputs:

| Input | Default | Purpose |
|---|---|---|
| `model` | `zai.glm-5` | Bedrock model for the orchestrator and review subagents |
| `subagent_model` | `nvidia.nemotron-super-3-120b` | Cheaper model for mechanical subagents (comment categorization/lifecycle) |
| `max_comments` | `10` | Inline comment cap per run; overflow lands in the summary |
| `aws_region` | `us-east-1` | Bedrock region |
| `boris_mcp_url` | _(empty)_ | Enable BORIS live-infrastructure context (see below) |
| `show_full_output` | `false` | Verbose OpenCode logs in the job output |

Repos can also tune the review without touching the caller via
`.github/ai-review.yml` in the reviewed repository (read from the PR branch,
values sanitized):

```yaml
model: zai.glm-5
max_comments: "10"
additional_dimensions:
  - iac
```

### One-time setup (per GitHub organization)

#### 1. GitHub App — the reviewer's comment identity

Create an app (org **Settings → Developer settings → GitHub Apps → New GitHub
App**):

- **Name**: e.g. `acme-ai-review`. The app slug becomes the comment author
  (`acme-ai-review[bot]`); dedicate the app to the reviewer — do not share the
  identity with other automation.
- **Webhook**: uncheck *Active* (no webhook is needed).
- **Where can this app be installed**: *Only on this account*.
- **Repository permissions** (everything else stays *No access*):

| Permission | Access | Used for |
|---|---|---|
| Pull requests | Read and write | inline review comments, replies, thread resolution |
| Issues | Read and write | the summary comment (PR top-level comments use the issues API) |
| Metadata | Read | mandatory, added automatically |

After creating the app:

1. note the **App ID**;
2. generate a **private key** (downloads a `.pem`);
3. **install the app** on the organization, granting it access to every
   repository that will use the review;
4. store two org-level Actions secrets, visible to those repositories:
   `APP_ID` (the numeric id) and `APP_PRIVATE_KEY` (the full PEM contents).

#### 2. AWS IAM role — Bedrock access via OIDC

The workflow assumes an IAM role through GitHub's OIDC provider; the runner
never holds long-lived AWS credentials. Example using
[terraform-aws-modules/iam/aws](https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest):

```hcl
data "aws_caller_identity" "current" {}

# The OIDC provider is 1 per AWS account — create it once,
# skip this block if the account already has it.
module "github_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-oidc-provider"
  version = "~> 6.0"

  url = "https://token.actions.githubusercontent.com"
}

module "ai_review_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "github-actions-ai-code-review"

  enable_github_oidc = true
  # One role serves every repo in the org that adopts the review.
  # Tighten to ["acme/some-repo:*"] entries if you prefer per-repo trust.
  oidc_wildcard_subjects = ["acme/*"]

  create_inline_policy = true
  inline_policy_permissions = {
    BedrockInvoke = {
      actions = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      resources = [
        # Foundation-model ARNs carry no account id; the region wildcard
        # keeps cross-region inference profiles working.
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/*",
      ]
    }
  }
}
```

Store `module.ai_review_role.arn` as an org secret (at FivexL:
`DEVELOPMENT_ACCOUNT_ROLE_ARN`) and map it to the workflow's
`BEDROCK_ROLE_ARN` in the caller. Model choice stays a workflow-config
concern — switching models never requires an IAM change.

Also enable the models you plan to use under **Model access** in the Bedrock
console for the chosen region.

### BORIS live infrastructure context (optional)

[BORIS](https://github.com/sirob-tech/boris-mcp-cli) is an MCP server that
indexes AWS infrastructure: live resources, topology, code-to-infrastructure
relationships, and prior operational decisions. Plugging it into the review
gives the AI real deployment context instead of guesses — most valuable when
reviewing infrastructure-as-code changes ("does this security group actually
front anything?", "is this the only consumer of that queue?").

Enable it by setting the input in the caller workflow:

```yaml
    with:
      boris_mcp_url: https://boris.example.com/mcp
```

How it works:

- the workflow installs the `bmcp` CLI from a pinned, SHA256-verified GitHub
  release of `sirob-tech/boris-mcp-cli`;
- `bmcp` authenticates to the BORIS endpoint with AWS SigV4 using the same
  OIDC role the workflow already assumed — no additional secrets;
- review subagents get **read-only** access to BORIS tools (resource lookups,
  infrastructure graph queries, memory search) and are told to use them when
  the dimension involves infrastructure;
- BORIS being unreachable degrades gracefully — the review runs without it.

`boris_mcp_url` is intentionally a **workflow input, not repo config**: the
org-controlled caller decides whether live infrastructure context is exposed,
never the PR branch.

### Security notes

- `.github/ai-review.yml` comes from the PR branch and is treated as
  untrusted input — every value is sanitized before it reaches a prompt or a
  CLI flag.
- The caller only runs for non-draft PRs from the same repository — never for
  forks.
- CLI binaries (OpenCode, bmcp) are installed from release assets pinned by
  version **and** SHA-256; a checksum mismatch fails the job.
- The reviewer's GitHub App carries the minimum permission set (pull
  requests, issues); it cannot push code, approve PRs, or read secrets.

## License

GPL-3.0 — see [LICENSE](LICENSE).

# Handoff: ai-code-review workflow v2 redesign

Status: **IMPLEMENTED on branch `2026-07-03-ai-code-review-v2`** (not yet PR'd).
Date: 2026-07-03. Interview conducted in Claude Code; all decisions below are
user-confirmed.

Implementation notes (delta vs. the plan below):
- All OPEN items resolved: bmcp v0.2.0 linux-amd64 SHA256 is
  `cd32f36b932a26bee0db9c71c416ff0a8786429aa4d1dcf28d9077797053236c` (pinned in
  workflow env); bmcp is configured non-interactively via
  `bmcp init --url <url> --non-interactive` then `bmcp sync`; bmcp
  init/sync/doctor failures are soft (warning), checksum failure is fatal.
- Placeholder substitution in agent files uses `perl -pi -e` with $ENV (BSD sed
  has no GNU-style `-i`; perl is portable and injection-safe).
- Validated locally: YAML parses; embedded Python extracted, byte-compiled, and
  integration-tested in a scratch git repo with fake gh/yq shims (config
  sanitization rejects malicious model/max_turns/dimensions; precompute splits
  per-file diffs, discovers rules files incl. per-dir AGENTS.md, assembles
  review-context.md, emits skip_review); agent-definitions step verified
  (model substituted, heredocs intact).
- `subagent_model` default: `nvidia.nemotron-super-3-120b` (verified ON_DEMAND
  in us-east-1 via BORIS).
- First real-PR run should watch: OpenCode task-tool subagent invocation by
  name, and Nemotron's reliability on the categorizer/lifecycle roles.

## Goal

Improve `.github/workflows/ai-code-review.yml` (reusable AI PR-review workflow,
OpenCode + Bedrock) by adopting patterns from the hellohippo example in `tmp/`:

- `tmp/step-ci-claude-code-review-v1.yml` — the reference reusable workflow (Claude Code based)
- `tmp/comment-categorizer.md` — haiku subagent that categorizes existing bot comments
- `tmp/comment-lifecycle.md` — haiku subagent that posts/resolves/upserts comments via helper scripts
- `tmp/ai-code-review.yml` — just the example's thin caller, not important

## Current state of this repo

- `.github/workflows/ai-code-review.yml` — reusable workflow, OpenCode CLI + Bedrock
  (default model `zai.glm-5`). One monolithic orchestrator prompt does review AND
  comment lifecycle with freehand `gh api` calls. Pre-compute steps are bash.
  Data dir: `.ai-review-work/` inside the worktree (OpenCode auto-rejects `/tmp`
  paths as external_directory in non-interactive runs — keep everything in worktree).
- `.github/workflows/ai-code-review-caller.yml` — caller for this repo (passes only
  secrets APP_ID, APP_PRIVATE_KEY, BEDROCK_ROLE_ARN; has concurrency group).
- `workflow-templates/ai-review-caller.yml` — adoption template for other repos.
- `.github/scripts/gh-resolve-review-thread.sh` — standalone GraphQL thread
  resolve/unresolve script. Currently UNUSED by the workflow. Keep as manual tool;
  its logic gets absorbed into the new Python CLI.

## Confirmed design decisions (user-approved)

1. **Runtime**: keep OpenCode + Bedrock. Do NOT switch to Claude Code. Port the
   example's *patterns*.
2. **Delivery**: everything embedded in the single reusable workflow YAML via
   heredocs, written to the worktree at runtime. Rationale: the workflow is copied
   into each org's shared repo and called via `workflow_call`; reusable workflows
   only ship the YAML (runner checks out the CALLING repo), so sibling files would
   need a second checkout — rejected in favor of self-contained YAML.
3. **Architecture**: full subagent split like the example:
   - Orchestrator (main model) reads one assembled context file, picks dimensions,
     spawns subagents, collects findings, hands off to lifecycle agent.
   - `comment-categorizer` subagent (cheap model) → writes `comment-categories.json`
     with `{active, stale, summary, no_issues}` comment-ID arrays.
   - `comment-lifecycle` subagent (cheap model) → executes post/reply/resolve/upsert
     via the Python CLI; must respect human replies like "false positive",
     "intended", "won't fix" (add those threads to handled set, don't re-litigate).
   - Subagent definitions written to `.opencode/agent/*.md` at runtime (OpenCode
     agent format: frontmatter with description/mode/model/tools).
4. **Dimensions**: exactly **2–3**, auto mode only (orchestrator picks from the diff).
   Canonical defaults: business_logic, security, performance (prompts exist in the
   example, port them). `additional_dimensions` from repo config are forced in and
   count toward the limit. NO static mode knob, NO pluggable specialist mechanism
   in v1 (explicitly deferred; the example's @phi-compliance-reviewer pattern was
   discussed and postponed).
5. **Findings pipeline**: structured findings `{file, line, message, dimension,
   severity}`; dedup same file+line across dimensions; severity filter (only
   production bug/data-loss/security, user-measurable perf regression, or explicit
   AGENTS.md/CLAUDE.md rule violations — "when in doubt, drop it"); consolidate
   repeated patterns across files into one finding; cap at `max_comments`
   (default **10**); overflow becomes "Additional observations" in the summary.
6. **Language**: ALL logic moves from bash into ONE embedded **Python 3.12
   stdlib-only** CLI (heredoc'd into the workflow, e.g. `.ai-review-work/bin/ai_review.py`).
   Shells out to `gh` for all GitHub API calls (auth via GH_TOKEN). No pip installs.
   Exception: YAML config parsing may shell out to `yq` (preinstalled on
   ubuntu-latest, already used today) — `yq -o=json` then `json.loads`.
   Subcommands:
   - `config` — read+sanitize `.github/ai-review.yml`, emit GITHUB_OUTPUT lines
   - `precompute` — changed files, per-file diff split (avoids read-tool token
     limits; `/` → `__` in filenames), PR patches JSON, bot root comments, ALL
     thread replies incl. humans (with author field), bot issue comments,
     summary-comment-id, rules-file discovery (AGENTS.md, CLAUDE.md,
     .claude/CLAUDE.md, .claude/rules/*.md, per-dir AGENTS.md up the tree of each
     changed file), generated-only check (skip_review output), assemble single
     `review-context.md`
   - agent-facing ops: `post-inline <file> <line> <body>`, `reply <id> <body>`,
     `resolve-reply <id> [msg]`, `upsert-summary <body>`, `delete-comment <id> [issue|review]`
     (repo/PR/SHA baked in via env; warn-and-continue on failures)
   - `resolve-threads` — deterministic post-step: GraphQL scan for unresolved
     threads started by the bot that carry a bot reply matching
     `(?i)(resolved|no longer part of the diff|issue appears resolved)`, then
     resolveReviewThread mutation. NOTE: GraphQL author.login has NO `[bot]`
     suffix (use APP_SLUG); REST uses `APP_SLUG[bot]`. Warn if exactly 100
     threads fetched (pagination limit).
   - `dedupe-summaries` — deterministic post-step: keep newest
     `<!-- ai-review-summary -->` comment, delete older duplicates.
7. **Thread resolution**: deterministic post-step ONLY (agent just posts the
   explanatory reply; the post-step does the GraphQL resolve). User explicitly
   chose this over agent-invoked resolve.
8. **Approve-when-clean step: REMOVE.** Humans approve PRs. Delete the current
   "Approve PR when no unresolved bot review threads" step entirely.
9. **Config surface**:
   - Repo `.github/ai-review.yml` (read from PR branch, sanitized scalars only,
     port the example's validation regexes): `model` (`^[a-zA-Z0-9._-]+$`),
     `max_turns` (digits), `max_comments` (digits), `additional_dimensions`
     (each `^[a-zA-Z0-9_-]+$`).
   - workflow_call inputs: `aws_region` (default us-east-1), `model` (default
     `zai.glm-5`), `max_turns` (default 20), `show_full_output`,
     `subagent_model` (default `nvidia.nemotron-super-3-120b` — verified
     available ON_DEMAND in us-east-1 via BORIS; user explicitly wanted an
     NVIDIA 120B model; used as `amazon-bedrock/<id>` in OpenCode agent
     frontmatter), `boris_mcp_url` (default "" = disabled).
   - DROP the vestigial `review_plugin` / `plugin_marketplace_repo` inputs
     (OpenCode doesn't load Claude marketplace plugins; current handling is a
     no-op notice). Callers don't pass them, safe to remove.
   - Secrets unchanged: APP_ID, APP_PRIVATE_KEY, BEDROCK_ROLE_ARN.
10. **MCP**: generic MCP mechanism DROPPED for v1. BORIS only:
    - `boris_mcp_url` is a workflow_call input (org-controlled caller sets it;
      NOT readable from repo config — this was the injection-safety decision).
    - When set: install **bmcp** from `sirob-tech/boris-mcp-cli` GitHub release
      **v0.2.0**, asset `bmcp-linux-amd64.tar.gz`, verify against the release's
      `checksums.txt` (pin version + SHA256 in workflow env, same pattern as the
      existing OpenCode install step).
    - bmcp auth reuses the existing Bedrock OIDC role (AWS SigV4) — no new secrets.
    - Review subagents get told bmcp is available (read-only) for live AWS/infra
      context, useful when reviewing IaC changes.
11. **Keep from current workflow**: OpenCode pinned-release install with SHA256
    verification (OPENCODE_RELEASE v1.3.15), checkout of PR head sha with
    fetch-depth 0, GitHub App token generation, `pull_request` trigger semantics
    in caller (non-draft, same-repo), concurrency group in caller, generated-only
    skip check (files under .github/workflows/ whose first 5 lines contain
    "automatically generated from:").
12. **Adopt from example additionally**: single assembled `review-context.md`
    (changed files + per-file diffs + bot comments + thread replies + summary id
    + additional dims + rules file contents) so the orchestrator reads ONE file
    instead of hunting; "do NOT re-fetch comments at runtime — use only
    pre-computed files" rule; `--max-turns`-equivalent note (OpenCode `run` has
    no such flag in the pinned build — max_turns stays informational).

## OPEN items (verify before/while implementing)

1. **bmcp checksum**: fetch
   `https://github.com/sirob-tech/boris-mcp-cli/releases/download/v0.2.0/checksums.txt`
   and pin the `bmcp-linux-amd64.tar.gz` SHA256 in the workflow env.
   (Attempted; the fetch was interrupted — not yet retrieved.)
2. **bmcp configuration mechanism**: how the MCP URL is supplied (env var? `bmcp
   init` config file? flag?). Check `bmcp help` / repo README. Locally bmcp is
   installed via homebrew tap `sirob-tech/tap` (v0.2.0) and `bmcp doctor` works.
   The workflow needs a non-interactive way to point bmcp at `boris_mcp_url`.
3. **OpenCode subagent invocation in non-interactive `run`**: agent .md files in
   `.opencode/agent/` with `mode: subagent`; orchestrator invokes via the task
   tool. Verify frontmatter fields (description, mode, model, tools) against
   OpenCode v1.3.15 docs and that `model: amazon-bedrock/<id>` per-agent override
   works.
4. Whether dimension-review subagents run as anonymous task-tool spawns on the
   main model (design intent) or need their own agent files.

## Implementation plan (not started)

1. Feature branch off main.
2. Rewrite `.github/workflows/ai-code-review.yml`:
   checkout → app token → git identity → AWS OIDC → write Python CLI (heredoc) →
   `config` step → `precompute` step (gates rest via skip_review) → install
   OpenCode → conditional bmcp install → write `.opencode/agent/*.md` +
   `opencode.json` → orchestrator `opencode run` with rewritten prompt →
   post-step `resolve-threads` → post-step `dedupe-summaries`.
3. Update `ai-code-review-caller.yml` and `workflow-templates/ai-review-caller.yml`
   (drop removed inputs if referenced; they currently only pass secrets — likely
   unchanged apart from comments; optionally document `boris_mcp_url`).
4. Leave `.github/scripts/gh-resolve-review-thread.sh` untouched (manual utility).
5. Validate YAML (actionlint if available), sanity-check Python CLI with
   `python3 -m py_compile` / local dry-run of pure functions.

## Context notes for the next agent

- `tmp/` is untracked scratch space holding the examples; don't delete, don't ship.
- Repo root has a `workflows -> .github/workflows` symlink.
- The example workflow's prompt-injection sanitization exists because
  `.github/ai-review.yml` comes from the PR branch — keep that property.
- User works at FivexL (AWS consultancy); BORIS/bmcp is their infra-context MCP
  (see `~/.claude/BORIS.md` for bmcp usage).

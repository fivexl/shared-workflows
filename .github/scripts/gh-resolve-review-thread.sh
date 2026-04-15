#!/usr/bin/env bash
# Resolve or unresolve a pull request review thread via GitHub GraphQL — the same
# action as the "Resolve conversation" / "Re-open conversation" buttons in the UI.
# REST-only replies (in_reply_to) do not set the resolved state on the thread.
#
# Requires: gh CLI authenticated (e.g. gh auth login)
#
# Run `gh-resolve-review-thread.sh help` for usage.
#
# <review_comment_database_id> is the numeric "id" from:
#   gh api repos/{owner}/{repo}/pulls/comments/{id}
# or the "id" field on inline review comments in the REST API.
#
# GraphQL limits (GitHub API): at most 100 review threads and 50 comments per thread
# per query. PRs with more threads/comments than that need pagination added here.

set -euo pipefail

usage() {
  local code="${1:-1}"
  cat <<'EOF'
Usage:
  gh-resolve-review-thread.sh resolve <owner> <repo> <pr_number> <review_comment_database_id>
  gh-resolve-review-thread.sh unresolve <owner> <repo> <pr_number> <review_comment_database_id>
  gh-resolve-review-thread.sh resolve-thread <PRRT_...node_id>
  gh-resolve-review-thread.sh unresolve-thread <PRRT_...node_id>
  gh-resolve-review-thread.sh list <owner> <repo> <pr_number>

<review_comment_database_id> is the numeric REST "id" from pull review comments (e.g. gh api repos/OWNER/REPO/pulls/comments/COMMENT_ID).
Requires: gh, jq
EOF
  exit "$code"
}

graphql() {
  gh api graphql "$@"
}

thread_id_for_comment() {
  local owner="$1" repo="$2" pr="$3" comment_id="$4"
  local out
  out="$(graphql -f query='
    query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              comments(first: 50) {
                nodes { databaseId }
              }
            }
          }
        }
      }
    }' -f owner="$owner" -f name="$repo" -F pr="$pr" \
    | jq --argjson cid "$comment_id" '
      (.data.repository.pullRequest.reviewThreads.nodes
      | map(select(any(.comments.nodes[]; .databaseId == $cid)))
      | .[0])
      | if . == null then empty else {id, isResolved} end
    ')"
  if [[ -z "$out" || "$out" == "null" ]]; then
    echo "error: no review thread contains comment database id ${comment_id}" >&2
    exit 1
  fi
  echo "$out"
}

cmd_resolve_thread() {
  local thread_id="$1"
  graphql -f query='
    mutation($id: ID!) {
      resolveReviewThread(input: {threadId: $id}) {
        thread { id isResolved }
      }
    }' -f id="$thread_id"
}

cmd_unresolve_thread() {
  local thread_id="$1"
  graphql -f query='
    mutation($id: ID!) {
      unresolveReviewThread(input: {threadId: $id}) {
        thread { id isResolved }
      }
    }' -f id="$thread_id"
}

cmd_list() {
  local owner="$1" repo="$2" pr="$3"
  graphql -f query='
    query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              comments(first: 20) {
                nodes { databaseId path }
              }
            }
          }
        }
      }
    }' -f owner="$owner" -f name="$repo" -F pr="$pr" \
    | jq -r '
      .data.repository.pullRequest.reviewThreads.nodes[]
      | "thread \(.id) resolved=\(.isResolved) comments=\([.comments.nodes[].databaseId]|join(","))"'
}

main() {
  [[ $# -ge 1 ]] || usage
  local sub="$1"
  shift

  case "$sub" in
    resolve)
      [[ $# -eq 4 ]] || usage
      local meta thread_id resolved
      meta="$(thread_id_for_comment "$1" "$2" "$3" "$4")"
      thread_id="$(echo "$meta" | jq -r '.id')"
      resolved="$(echo "$meta" | jq -r '.isResolved')"
      if [[ "$resolved" == "true" ]]; then
        echo "thread ${thread_id} already resolved"
        exit 0
      fi
      cmd_resolve_thread "$thread_id"
      echo "resolved thread ${thread_id}"
      ;;
    unresolve)
      [[ $# -eq 4 ]] || usage
      local meta thread_id resolved
      meta="$(thread_id_for_comment "$1" "$2" "$3" "$4")"
      thread_id="$(echo "$meta" | jq -r '.id')"
      resolved="$(echo "$meta" | jq -r '.isResolved')"
      if [[ "$resolved" == "false" ]]; then
        echo "thread ${thread_id} already unresolved"
        exit 0
      fi
      cmd_unresolve_thread "$thread_id"
      echo "unresolved thread ${thread_id}"
      ;;
    resolve-thread)
      [[ $# -eq 1 ]] || usage
      cmd_resolve_thread "$1"
      echo "resolved thread $1"
      ;;
    unresolve-thread)
      [[ $# -eq 1 ]] || usage
      cmd_unresolve_thread "$1"
      echo "unresolved thread $1"
      ;;
    list)
      [[ $# -eq 3 ]] || usage
      cmd_list "$1" "$2" "$3"
      ;;
    -h|--help|help)
      usage 0
      ;;
    *)
      echo "unknown command: $sub" >&2
      usage
      ;;
  esac
}

main "$@"

#!/usr/bin/env bash
#
# Merge changes INTO an existing branch ruleset instead of replacing it.
#
#   scripts/ruleset-add-required-check.sh owner/repo --name "main protection" \
#       --check "ci / test" --check "claude-review" [--integration-id 15368] \
#       [--approvals 1] [--dry-run]
#
# apply-branch-ruleset.sh PUTs a whole ruleset matched by name; on a repo that
# already has its own ruleset under a different name that ADDS a second
# ruleset, and rulesets combine as the union of restrictions — a required
# context nothing ever posts blocks every merge. This script GETs the named
# ruleset, appends the given required status checks (skipping ones already
# present), optionally sets the approval count, and PUTs the result back.
#
# --integration-id applies to every --check given after it; omit it for a
# status posted by a PAT (e.g. gemini-pr-review). 15368 = github-actions.
#
# Requires: gh (authenticated with admin on the repo), jq.
set -euo pipefail

REPO="" NAME="" APPROVALS="" DRY_RUN=0 INTEGRATION=""
CHECKS=()

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --check) CHECKS+=("$2|${INTEGRATION}"); shift 2 ;;
    --integration-id) INTEGRATION="$2"; shift 2 ;;
    --approvals) APPROVALS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown flag: $1" >&2; usage 1 ;;
    *) REPO="$1"; shift ;;
  esac
done
[[ -n "$REPO" && -n "$NAME" ]] || usage 1
for cmd in gh jq; do command -v "$cmd" >/dev/null || { echo "error: $cmd is required" >&2; exit 1; }; done

id=$(gh api "repos/${REPO}/rulesets" --jq --arg n "$NAME" 'map(select(.name == $n)) | first | .id // empty')
[[ -n "$id" ]] || { echo "error: no ruleset named '$NAME' on $REPO" >&2; exit 1; }

current=$(gh api "repos/${REPO}/rulesets/${id}")

# Only the writable fields go back; the GET payload carries read-only ones
# (id, node_id, _links, created_at ...) that the PUT rejects.
updated=$(jq '{name, target, enforcement, conditions, bypass_actors, rules}' <<<"$current")

for entry in "${CHECKS[@]}"; do
  ctx="${entry%%|*}"; integ="${entry##*|}"
  updated=$(jq --arg ctx "$ctx" --arg integ "$integ" '
    def check: if $integ == "" then {context: $ctx} else {context: $ctx, integration_id: ($integ | tonumber)} end;
    (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |=
      (if any(.[]; .context == $ctx) then . else . + [check] end)
  ' <<<"$updated")
done

if [[ -n "$APPROVALS" ]]; then
  updated=$(jq --argjson n "$APPROVALS" '
    (.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = $n
  ' <<<"$updated")
fi

echo "==> ${REPO} ruleset '${NAME}' (id ${id})"
jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | "    check: \(.context)"' <<<"$updated"
jq -r '.rules[] | select(.type == "pull_request") | "    approvals: \(.parameters.required_approving_review_count)"' <<<"$updated"

if [[ $DRY_RUN -eq 1 ]]; then echo "    DRY RUN: no changes written"; exit 0; fi

result=$(gh api --method PUT "repos/${REPO}/rulesets/${id}" --input - <<<"$updated")
echo "    OK: $(jq -r '"\(.name) enforcement=\(.enforcement)"' <<<"$result")"

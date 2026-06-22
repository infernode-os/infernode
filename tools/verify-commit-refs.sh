#!/bin/bash
#
# verify-commit-refs.sh — ensure a PR is linked to a Jira issue.
#
# Why this exists: work on this project routinely gets coded, merged, and
# even documented on the ticket ("Will move to Done on merge") — but the
# final Jira status transition gets forgotten, so In-Review / To-Do fills
# up with work that is actually finished.  The fix is to make the linkage
# machine-readable: if every PR carries at least one `INFR-<n>` reference,
# the companion automation (jira-transition-on-merge) can close the ticket
# for us the moment the PR lands on master.
#
# CLAUDE.md already asks for `Refs: INFR-<n>` in commit messages; this is
# the backstop that keeps the habit from rotting.
#
# What it checks: across the commit range (default origin/master..HEAD),
# at least one non-merge commit message must contain an `INFR-<n>` key.
#
# Escape hatch: a genuinely ticketless change (typo, CI tweak) can opt out
# by putting the literal token `[no-jira]` in any commit message in the
# range.
#
# Usage:
#   tools/verify-commit-refs.sh [<base-ref>] [<head-ref>]
#   BASE_REF=origin/master HEAD_REF=HEAD tools/verify-commit-refs.sh
#
# Exit codes:
#   0  at least one INFR ref found (or [no-jira] opt-out, or empty range)
#   1  commits present but none reference a Jira key

set -euo pipefail

base="${1:-${BASE_REF:-origin/master}}"
head="${2:-${HEAD_REF:-HEAD}}"

# Resolve the merge-base so we only inspect commits this branch adds.
if ! range_base=$(git merge-base "$base" "$head" 2>/dev/null); then
	# base ref not available (e.g. shallow checkout without it) — inspect
	# just the tip commit rather than fail the build spuriously.
	range_base="${head}^"
fi

# Non-merge commit subjects+bodies in the range.
msgs=$(git log --no-merges --format='%H%n%B' "${range_base}..${head}" 2>/dev/null || true)

if [ -z "$(echo "$msgs" | tr -d '[:space:]')" ]; then
	echo "verify-commit-refs: no non-merge commits in ${range_base}..${head}; nothing to check."
	exit 0
fi

if echo "$msgs" | grep -qiE '\[no-jira\]'; then
	echo "verify-commit-refs: [no-jira] opt-out present; skipping Jira-ref enforcement."
	exit 0
fi

if echo "$msgs" | grep -qoE 'INFR-[0-9]+'; then
	keys=$(echo "$msgs" | grep -oiE 'INFR-[0-9]+' | tr 'a-z' 'A-Z' | sort -u | paste -sd' ' -)
	echo "verify-commit-refs OK: PR references ${keys}."
	exit 0
fi

cat >&2 <<'EOF'
verify-commit-refs: FAIL — no Jira issue reference found in this PR's commits.

Add a reference like `Refs: INFR-123` to at least one commit message so the
ticket auto-closes when this PR merges to master (see CLAUDE.md, "Project
tracking — Jira").  Amend with:

    git commit --amend            # edit the message, add: Refs: INFR-123
    # or for an earlier commit: git rebase -i <base> and reword

Genuinely ticketless change? Put [no-jira] in a commit message to opt out.
EOF
exit 1

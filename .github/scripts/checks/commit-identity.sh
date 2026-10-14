#!/usr/bin/env bash
# Fails when a commit in <base>..<head> is not the founder's: every commit in
# this repo is authored and committed by the founder's GitHub account only.
#
#   .github/scripts/checks/commit-identity.sh <base> <head>
#
# Allowed author/committer: arrz.dev or arrzdev
# <55147716+arrzdev@users.noreply.github.com>, and Dependabot. Allowed as
# committer only: GitHub <noreply@github.com> (web edits, merges on GitHub).
# A commit message (or PR_BODY, when set: the squash merge uses it) must not
# carry Co-authored-by: / Signed-off-by: lines or "Generated with Claude Code"
# (Dependabot's own sign-off and co-author lines are allowed).
set -euo pipefail

base="$(git rev-parse --verify "${1:?usage: commit-identity.sh <base> <head>}^{commit}")"
head="$(git rev-parse --verify "${2:?usage: commit-identity.sh <base> <head>}^{commit}")"

founder_email='55147716+arrzdev@users.noreply.github.com'
dependabot='dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>'
trailers='^[[:space:]]*(co-authored-by|signed-off-by):|generated with \[?claude code'
bad_lines() { # stdin: a message -> its forbidden lines
  grep -iE "$trailers" | grep -viE '^[[:space:]]*(co-authored-by|signed-off-by):[[:space:]]*dependabot\[bot\] <' || true
}

person_ok() { # person_ok <role> "<name> <email>"
  case "$2" in
    "arrz.dev <$founder_email>" | "arrzdev <$founder_email>" | "$dependabot") return 0 ;;
    "GitHub <noreply@github.com>") [ "$1" = committer ] ;;
    *) return 1 ;;
  esac
}

bad=0
count=0
while IFS=$'\t' read -r sha author committer; do
  count=$((count + 1))
  for role in author committer; do
    who="${!role}"
    if ! person_ok "$role" "$who"; then
      echo "::error::${sha:0:12} $role is \"$who\": commit as the founder's account only"
      bad=1
    fi
  done
  lines="$(git log -1 --format=%B "$sha" | bad_lines)"
  if [ -n "$lines" ]; then
    echo "::error::${sha:0:12} message has a co-author, sign-off or generated-by line"
    printf '%s\n' "$lines" | sed 's/^/    /'
    bad=1
  fi
done < <(git log --format=$'%H\t%an <%ae>\t%cn <%ce>' "$base..$head")

if [ -n "$(printf '%s\n' "${PR_BODY:-}" | bad_lines)" ]; then
  echo "::error::PR description has a co-author, sign-off or generated-by line (it becomes the squash commit message)"
  bad=1
fi

if [ "$bad" -ne 0 ]; then
  echo "Fix: reset the identity (no GIT_AUTHOR_*/GIT_COMMITTER_* exports, no git -c user.*),"
  echo "then git rebase -r --exec 'git commit --amend --no-edit --reset-author' $base and force-push."
  exit 1
fi
echo "Commit identity: $count commit(s) in ${base:0:12}..${head:0:12}, all by the founder's account."

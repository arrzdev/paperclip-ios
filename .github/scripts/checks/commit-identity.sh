#!/usr/bin/env bash
# Fails when a commit in <base>..<head> carries a TUDU agent identity or an AI
# tool attribution. Our own commits use the founder's GitHub account only;
# outside contributors, Dependabot and GitHub pass as they are.
#
#   .github/scripts/checks/commit-identity.sh <base> <head>
#
# Fails on:
# - an author, committer, Co-authored-by: or Signed-off-by: that is a TUDU
#   identity: an @tudu.invalid/.dev/.local or @paperclip.ing email,
#   paperclip@localhost, a TUDU agent name, or the founder's noreply email
#   under a name other than arrz.dev/arrzdev;
# - a Co-authored-by: naming Claude or noreply@anthropic.com, and a
#   "Generated with [Claude Code]" line.
# With PR_BODY set it checks the PR description too: the squash merge uses it.
set -euo pipefail

base="$(git rev-parse --verify "${1:?usage: commit-identity.sh <base> <head>}^{commit}")"
head="$(git rev-parse --verify "${2:?usage: commit-identity.sh <base> <head>}^{commit}")"

founder_email='55147716+arrzdev@users.noreply.github.com'
agents='andre ferreira|tiago costa|miguel santos|ines duarte|marta reis|rui moreira|sofia lima|luis araujo|beatriz nunes|mariana lopes|joana pires|ana ribeiro|pedro alves|paperclip-agent'

fold() { # lowercase, without accents
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[áàâã]/a/g; s/[éèê]/e/g; s/[íì]/i/g; s/[óòôõ]/o/g; s/[úù]/u/g; s/ç/c/g; s/[ÁÀÂÃ]/a/g; s/[ÉÈÊ]/e/g; s/[ÍÌ]/i/g; s/[ÓÒÔÕ]/o/g; s/[ÚÙ]/u/g; s/Ç/c/g'
}

# why_bad "<name> <email>" -> prints the reason when the identity is ours or
# an AI tool, nothing when it is fine.
why_bad() {
  local name email
  name="$(fold "${1% <*}")"
  name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  email="$(fold "${1##*<}")"
  email="${email%%>*}"
  if [[ "$email" =~ @tudu\.(invalid|dev|local)$|@paperclip\.ing$|^paperclip@localhost$ ]]; then
    echo "TUDU agent email"
  elif [[ "$name" =~ ^($agents)$ ]]; then
    echo "TUDU agent name"
  elif [ "$email" = "$founder_email" ] && [ "$name" != arrz.dev ] && [ "$name" != arrzdev ]; then
    echo "founder email under another name"
  fi
}

# bad_lines: a message on stdin -> one line per forbidden line, with the reason
bad_lines() {
  local line value reason
  while IFS= read -r line; do
    if [[ "$(fold "$line")" =~ generated\ with\ \[?claude\ code ]]; then
      echo "AI attribution: $line"
    elif [[ "$line" =~ ^[[:space:]]*([Cc][Oo]-[Aa][Uu][Tt][Hh][Oo][Rr][Ee][Dd]-[Bb][Yy]|[Ss][Ii][Gg][Nn][Ee][Dd]-[Oo][Ff][Ff]-[Bb][Yy]):[[:space:]]*(.*)$ ]]; then
      value="${BASH_REMATCH[2]}"
      if [[ "$(fold "$value")" =~ claude|noreply@anthropic\.com ]]; then
        echo "AI attribution: $line"
      elif reason="$(why_bad "$value")" && [ -n "$reason" ]; then
        echo "$reason: $line"
      fi
    fi
  done
}

bad=0
bad_body=0
count=0
while IFS=$'\t' read -r sha author committer; do
  count=$((count + 1))
  for role in author committer; do
    reason="$(why_bad "${!role}")"
    if [ -n "$reason" ]; then
      echo "::error::${sha:0:12} $role is \"${!role}\" ($reason): commit as the founder's account only"
      bad=1
    fi
  done
  lines="$(git log -1 --format=%B "$sha" | bad_lines)"
  if [ -n "$lines" ]; then
    echo "::error::${sha:0:12} message has an agent or AI attribution line"
    printf '%s\n' "$lines" | sed 's/^/    /'
    bad=1
  fi
done < <(git log --format=$'%H\t%an <%ae>\t%cn <%ce>' "$base..$head")

lines="$(printf '%s\n' "${PR_BODY:-}" | bad_lines)"
if [ -n "$lines" ]; then
  echo "::error::PR description has an agent or AI attribution line (it becomes the squash commit message)"
  printf '%s\n' "$lines" | sed 's/^/    /'
  echo "Fix: edit the PR description, then push or close and reopen the PR (a re-run reuses the old text)."
  bad_body=1
fi

if [ "$bad" -ne 0 ]; then
  echo "Fix: unset any identity override (no GIT_AUTHOR_*/GIT_COMMITTER_* exports, no git -c user.*),"
  echo "drop the lines above from the messages, then"
  echo "git rebase -r --exec 'git commit --amend --no-edit --reset-author' $base and force-push."
fi
[ "$bad" -eq 0 ] && [ "$bad_body" -eq 0 ] || exit 1
echo "Commit identity: $count commit(s) in ${base:0:12}..${head:0:12}, no agent identity or AI attribution."

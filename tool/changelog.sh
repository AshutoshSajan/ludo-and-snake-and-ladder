#!/usr/bin/env bash
# Regenerate CHANGELOG.md from commit history, locally.
#
# This is the same generator the CI "changelog" job used to run, moved here
# because that job costs runner minutes and this does not. CHANGELOG.md is
# generated, never hand-edited — the rules live in cliff.toml.
#
# The pre-push hook calls this in --check mode on staging/main pushes, so the
# changelog is verified to match history at the moment it matters instead of
# being patched up by a bot afterwards.
#
# Usage:
#   tool/changelog.sh           rewrite CHANGELOG.md
#   tool/changelog.sh --check   fail (exit 1) if it is out of date; change nothing
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if ! command -v git-cliff >/dev/null 2>&1; then
  echo "error: git-cliff is not installed." >&2
  echo "  macOS:  brew install git-cliff" >&2
  echo "  Debian: see https://git-cliff.org/docs/installation/" >&2
  exit 127
fi

check=false
[ "${1:-}" = "--check" ] && check=true

# git-cliff resolves versioned sections from tags, so a shallow clone silently
# produces a changelog with the release history missing. The CI job hit exactly
# this and needed fetch-depth: 0; here the equivalent is a full history.
if [ "$(git rev-list --count HEAD)" -lt 50 ] && [ -z "$(git tag | head -1)" ]; then
  echo "warning: history looks shallow and there are no tags." >&2
  echo "         run 'git fetch --unshallow --tags' for a complete changelog." >&2
fi

before=$(mktemp)
out=$(mktemp)
trap 'rm -f "$before" "$out"' EXIT
[ -f CHANGELOG.md ] && cp CHANGELOG.md "$before"

git-cliff --config cliff.toml --output "$out"

# A regeneration that drops a released section means this branch is missing
# commits its base has — the changelog would erase history rather than add to
# it. This is the check that made the CI job worth keeping, so it stays.
missing=$(comm -23 \
  <(grep '^## ' "$before" 2>/dev/null | sort) \
  <(grep '^## ' "$out" | sort))
if [ -n "$missing" ]; then
  echo "error: regenerated CHANGELOG.md would drop section(s):" >&2
  echo "$missing" | sed 's/^/  /' >&2
  echo "This branch is missing commits the base branch has. Merge the base in, then retry." >&2
  exit 1
fi

if $check; then
  if diff -q "$before" "$out" >/dev/null 2>&1; then
    echo "CHANGELOG.md matches history — nothing to do."
    exit 0
  fi
  echo "error: CHANGELOG.md is out of date for this history." >&2
  git --no-pager diff --no-index --stat "$before" "$out" >&2 || true
  echo >&2
  echo "  fix:  tool/changelog.sh && git add CHANGELOG.md && git commit --amend --no-edit" >&2
  exit 1
fi

cp "$out" CHANGELOG.md
git --no-pager diff --stat -- CHANGELOG.md || true
echo "CHANGELOG.md regenerated."

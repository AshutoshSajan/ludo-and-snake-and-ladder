#!/usr/bin/env bash
# Choose the version a release-prep run should declare.
#
# `tool/version.sh --bump` derives its answer from the highest v* tag. That is
# right while main and the tag agree, but main can already declare a version
# that has not been tagged yet: a feature merged after v1.2.1 declares 1.3.0,
# and --bump keeps returning 1.3.0 until a v1.3.0 tag exists. Treating
# `next == base` as "nothing to do" skipped the changelog regeneration too, so
# a stale CHANGELOG.md then failed the verify step on every push.
#
# This script answers the only question the version step needs: which of the
# declared version and the tag-derived version is the release target. It never
# returns a lower version than the one already declared - a release-prep run
# must not move the project backwards when history is behind the tag.
#
# Usage:
#   tool/release_target.sh <declared> <tag-derived>
#
# Prints the target version. Writes why to stderr when the tag-derived version
# is older than the declared one.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: tool/release_target.sh <declared> <tag-derived>" >&2
  exit 2
fi

declared=$1
derived=$2

for v in "$declared" "$derived"; do
  [[ $v =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || {
    echo "error: '$v' is not a valid version" >&2
    exit 2
  }
done

# Numeric comparison, component by component. Leading zeroes and missing
# components are safe; lexical sorting would put 1.9.0 above 1.10.0.
version_greater() {
  local IFS=.
  local -a left right
  read -r -a left <<< "$1"
  read -r -a right <<< "$2"
  local i a b
  for i in 0 1 2; do
    a=${left[i]:-0}
    b=${right[i]:-0}
    if ((10#$a > 10#$b)); then return 0; fi
    if ((10#$a < 10#$b)); then return 1; fi
  done
  return 1
}

if version_greater "$derived" "$declared"; then
  echo "$derived"
else
  if [ "$derived" != "$declared" ]; then
    echo "declared version $declared is ahead of tag-derived $derived; keeping $declared" >&2
  fi
  echo "$declared"
fi

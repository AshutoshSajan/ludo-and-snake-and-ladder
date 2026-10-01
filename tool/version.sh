#!/usr/bin/env bash
# Read or write the project version, in one place.
#
# The version was declared in three files that had already drifted apart:
# pubspec.yaml said 1.0.0, both extension manifests said 1.0.0, and the tags
# said v1.1.0. AMO rejects an upload whose version does not increase, and the
# Web Store rejects a repeat, so a version that disagrees with reality fails at
# the worst moment - during a release, with credentials in hand.
#
# This script is the only thing that writes those three fields, so they cannot
# drift again. CI calls it on push; a human can call it by hand.
#
# Usage:
#   tool/version.sh              print the current version, e.g. 1.0.0
#   tool/version.sh --bump       print the next version, without writing
#   tool/version.sh --set 1.2.0  write that version everywhere
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PUBSPEC=pubspec.yaml
MANIFESTS=(extension/manifest.chrome.json extension/manifest.firefox.json)

die() { echo "error: $*" >&2; exit 1; }

current() { sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' "$PUBSPEC" | head -1; }

# The highest tag, not the most recent one. `git tag` sorts lexically, so v1.9.0
# would sort below v1.10.0 and the wrong "latest" would be picked.
latest_tag_version() {
  git tag --list 'v[0-9]*' --sort=-v:refname | head -1 | sed 's/^v//'
}

bump() {
  local v=$1 major minor patch
  IFS=. read -r major minor patch <<<"$v"
  : "${major:=0}" "${minor:=0}" "${patch:=0}"
  echo "$major.$((minor + 1)).0"
}

case "${1:-}" in
  '')
    current
    ;;
  --bump)
    latest=$(latest_tag_version)
    [ -n "$latest" ] || die "no v* tags found; pass --set <version> explicitly"
    echo "declared $(current), latest tag v$latest" >&2
    bump "$latest"
    ;;
  --set)
    v=${2:-}
    [ -n "$v" ] || die "--set needs a version, e.g. --set 1.2.0"
    # Extension manifests accept only 1-4 dot-separated integers, each < 65536.
    # pubspec additionally takes a +build suffix. Validating here means a typo
    # fails on a laptop instead of at AMO.
    [[ $v =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || die "'$v' is not a valid extension version"
    IFS=. read -r a b c d <<<"$v"
    for n in $a $b $c $d; do
      [ -n "$n" ] || continue
      [ "$n" -lt 65536 ] || die "component '$n' exceeds 65535"
    done
    sed -i.bak -E "s/^version: .*/version: $v+1/" "$PUBSPEC" && rm -f "$PUBSPEC.bak"
    for m in "${MANIFESTS[@]}"; do
      [ -f "$m" ] || die "$m is missing"
      sed -i.bak -E "s/(\"version\": \")[^\"]*(\")/\1$v\2/" "$m" && rm -f "$m.bak"
    done
    echo "$v"
    ;;
  *)
    die "unknown argument '$1' (expected nothing, --bump, or --set <version>)"
    ;;
esac

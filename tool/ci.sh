#!/usr/bin/env bash
# The local quality gate — the same checks the CI "test" job runs, on your
# machine, for free.
#
# This exists because GitHub-hosted runner minutes are a metered resource and
# this repo exhausted them. It is the fast path, not the only path: it runs in
# seconds instead of queueing for a runner, so it catches a broken build before
# a branch is pushed rather than after.
#
# What it is NOT: enforcement. A hook lives in your clone, is skipped by
# --no-verify, and does not run on merges you make from the GitHub UI. It
# protects the person who remembers to push, not the repository. The workflow in
# .github/workflows/ci.yml still runs when quota is available and remains the
# only real backstop.
#
# Usage:
#   tool/ci.sh            analyze + test          (~30s)
#   tool/ci.sh --web      also build web release  (~90s)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "flutter analyze --fatal-infos"
# Matches CI exactly. --fatal-infos is what makes an unused import or a stray
# doc comment fail the build rather than scroll past.
flutter analyze --fatal-infos

step "flutter test"
flutter test

if [ "${1:-}" = "--web" ]; then
  step "flutter build web --release"
  # Netlify runs this on every main deploy, so it is the one check that would
  # otherwise have no local coverage at all.
  flutter build web --release
fi

printf '\n\033[32mAll local checks passed.\033[0m\n'

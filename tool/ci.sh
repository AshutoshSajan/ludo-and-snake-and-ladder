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
#   tool/ci.sh            analyze + test + release web build   (~2 min)
#   tool/ci.sh --web      the same — the flag predates the web step
#                         moving into the default run, kept so old
#                         invocations and muscle memory keep working
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "flutter analyze --fatal-infos"
# Matches CI exactly. --fatal-infos is what makes an unused import or a stray
# doc comment fail the build rather than scroll past.
flutter analyze --fatal-infos

step "flutter test"
flutter test

step "flutter build web --release"
# The web-only half of the app that analyze + test cannot see: under a
# conditional export the analyzer resolves only the native branch, so a web
# file can hold a missing symbol that no test ever loads (this shipped once —
# voice_speaking_web reached dev with an unimported probe and only failed
# under `flutter run -d chrome`). The release build is the check that catches
# it on every push, locally, for free.
flutter build web --release

printf '\n\033[32mAll local checks passed.\033[0m\n'

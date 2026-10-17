#!/usr/bin/env bash
# Local dependency health check — the same concerns as
# .github/workflows/deps-audit.yml, on your machine, no runner queue.
#
# Two layers:
#   1. osv-scanner (if installed) scans the committed pubspec.lock against
#      OSV.dev advisories — how a vulnerable transitive dep is caught BEFORE
#      it ever lands. Install hint is printed when missing.
#   2. dart pub outdated lists what drifts — informational, not a gate: fresh
#      versions arrive via Dependabot PRs weekly; this is just the local view.
#
# Usage:
#   tool/deps.sh            # scan + report
#   tool/deps.sh --offline  # skip the outdated network half
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

failed=0

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

if command -v osv-scanner >/dev/null 2>&1; then
  step "OSV scan of pubspec.lock"
  # Repo dir passed as the walk root — see deps-audit.yml for why.
  if ! osv-scanner scan --lockfile=pubspec.lock "$PWD"; then
    failed=1
  fi
else
  step "OSV scan of pubspec.lock"
  echo "⏭  osv-scanner not installed — the advisory half is skipped."
  echo "   install: curl -fsSL https://github.com/google/osv-scanner/releases/download/v2.7.0/osv-scanner_$(uname -s | tr '[:upper:]' '[:lower:]')_$(dpkg --print-architecture 2>/dev/null || echo amd64) -o ~/bin/osv-scanner && chmod +x ~/bin/osv-scanner"
  echo "   (CI runs the scan weekly regardless; this is only the local view.)"
fi

if [ "${1:-}" != "--offline" ]; then
  step "dart pub outdated (informational)"
  dart pub outdated || true
fi

if [ "$failed" -ne 0 ]; then
  printf '\n\033[31m[deps] vulnerable dependencies — patch before pushing.\033[0m\n' >&2
  exit 1
fi
printf '\n\033[32mDependency scan clear.\033[0m\n'

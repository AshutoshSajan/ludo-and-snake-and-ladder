#!/bin/bash
# Local screenshot capture script
# Run from repo root: ./tools/capture-screenshots.sh

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "Building Flutter web release..."
flutter build web --release --wasm

echo "Starting HTTP server..."
cd build/web
python3 -m http.server 8080 &
SERVER_PID=$!
sleep 3

echo "Installing Playwright dependencies..."
cd "$REPO_ROOT/.github/scripts"
npm ci 2>/dev/null || npm install
npx playwright install chromium 2>/dev/null || npx playwright install chromium

echo "Capturing screenshots..."
node capture-screenshots.js

echo "Stopping HTTP server..."
kill $SERVER_PID 2>/dev/null || true

echo "Done! Screenshots saved to assets/screenshots/"
ls -la "$REPO_ROOT/assets/screenshots/"
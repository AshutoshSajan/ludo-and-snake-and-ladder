#!/usr/bin/env bash
# Package the Flutter web build as a Chrome (MV3) extension.
#
# Usage:
#   flutter build web --release          # if build/web is stale
#   ./tools/build_extension.sh           # -> build/extension/ (load unpacked)
#   ./tools/build_extension.sh --zip     # also writes build/game-club-extension.zip
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f build/web/index.html ] || { echo 'build/web missing — run: flutter build web --release' >&2; exit 1; }

# 1. fresh extension skeleton (icons first; manifest copied last so the
#    web build's own manifest.json cannot overwrite it)
rm -rf build/extension
mkdir -p build/extension
python3 tools/gen_extension_icons.py
cp -r build/web/. build/extension/
cp extension/manifest.json extension/background.js build/extension/
cp -r extension/icons/. build/extension/icons/

# 3. rewrite bootstrap so the engine loads CanvasKit from the package.
#    MV3 CSP forbids remote scripts, but the built bootstrap prefers the
#    gstatic CDN unless useLocalCanvasKit is set. build/web already ships
#    a local canvaskit/ folder — flip the flag to use it.
python3 - <<'PY'
import pathlib, re
p = pathlib.Path('build/extension/flutter_bootstrap.js')
s = p.read_text()
s2, n = re.subn(r'("engineRevision":"[0-9a-f]+")', r'\1,"useLocalCanvasKit":true', s, count=1)
if n == 0:
    raise SystemExit('could not find engineRevision in flutter_bootstrap.js')
p.write_text(s2)
print('bootstrap pinned to local canvaskit')
PY

# 4. sanity: no remote script/font/wasm references may remain anywhere
echo '--- remote refs remaining (must be none): ---'
grep -rEoh 'https?://[a-zA-Z0-9./_-]+\.(js|wasm|json|ttf)' build/extension --include='*.js' --include='*.html' || echo 'none ✓'

# 5. optional zip for the Web Store
if [ "${1:-}" = '--zip' ]; then
  (cd build/extension && zip -qr ../game-club-extension.zip .)
  echo "wrote build/game-club-extension.zip"
fi

echo
echo "Extension ready → build/extension"
echo "Load it: chrome://extensions → Developer mode → Load unpacked → select build/extension"

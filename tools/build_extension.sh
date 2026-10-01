#!/usr/bin/env bash
# Package the Flutter web build as a browser extension.
#
#   ./tools/build_extension.sh                # Chrome (MV3, service worker)
#   ./tools/build_extension.sh --firefox      # Firefox (MV3, event page)
#   ./tools/build_extension.sh --firefox --zip
#
# The two browsers need different manifests, not different builds. Chrome MV3
# runs the toolbar handler as a service worker; Firefox MV3 has no service
# workers and requires an event page (`background.scripts`) instead. A manifest
# carrying `service_worker` is rejected by Firefox, and one carrying `scripts`
# is ignored by Chrome, so the target picks the file rather than the build.
#
# Everything else is shared: the same Flutter output, the same local CanvasKit
# (MV3 forbids remote scripts), the same icons.
set -euo pipefail
cd "$(dirname "$0")/.."

target=chrome
want_zip=0
for arg in "$@"; do
  case "$arg" in
    --firefox) target=firefox ;;
    --chrome) target=chrome ;;
    --zip) want_zip=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ -f build/web/index.html ] || {
  echo 'build/web missing — run: flutter build web --release' >&2
  exit 1
}

out="build/extension-$target"
# 1. fresh skeleton (icons first; the manifest is copied last so the web
#    build's own manifest.json cannot overwrite it)
rm -rf "$out"
mkdir -p "$out"
python3 tools/gen_extension_icons.py >/dev/null
cp -r build/web/. "$out"/
cp "extension/manifest.$target.json" "$out/manifest.json"
cp extension/background.js "$out"/
cp -r extension/icons/. "$out/icons/"

# 2. A service worker cannot run in an extension page — there is no such
#    context — so shipping one only buys a failed registration in the console.
#    Drop it, and the registration Flutter's bootstrap attempts with it.
rm -f "$out/flutter_service_worker.js"
python3 - <<PY
import pathlib, re
p = pathlib.Path("$out/flutter_bootstrap.js")
s = p.read_text()
# 3. Pin the engine to the bundled CanvasKit. MV3 CSP forbids remote scripts,
#    but the built bootstrap prefers the gstatic CDN unless this is set.
s2, n = re.subn(r'("engineRevision":"[0-9a-f]+")', r'\1,"useLocalCanvasKit":true', s, count=1)
if n == 0:
    raise SystemExit('could not find engineRevision in flutter_bootstrap.js')
p.write_text(s2)
print('bootstrap pinned to local canvaskit')
PY

# 4. sanity: no remote script/font/wasm references may remain anywhere
echo '--- remote refs remaining (must be none): ---'
grep -rEoh 'https?://[a-zA-Z0-9./_-]+\.(js|wasm|json|ttf)' "$out" \
  --include='*.js' --include='*.html' || echo 'none ✓'

# 5. The manifest must be valid JSON, and must not carry the other browser's
#    background model. A silently wrong manifest installs and then does
#    nothing when clicked, which is an unpleasant way to find out.
python3 - "$out/manifest.json" "$target" <<'PY'
import json, sys
path, target = sys.argv[1], sys.argv[2]
m = json.load(open(path))
bg = m.get('background', {})
if target == 'firefox':
    assert 'service_worker' not in bg, 'Firefox MV3 rejects background.service_worker'
    assert 'scripts' in bg, 'Firefox MV3 needs background.scripts'
else:
    assert 'service_worker' in bg, 'Chrome MV3 needs background.service_worker'
print(f'manifest ok for {target}: background={list(bg)[0]}, v{m["version"]}')
PY

if [ "$want_zip" = 1 ]; then
  ext=zip
  [ "$target" = firefox ] && ext=xpi
  (cd "$out" && zip -qr "../game-club-$target.$ext" .)
  echo "wrote build/game-club-$target.$ext"
fi

echo
echo "Extension ready -> $out"
if [ "$target" = firefox ]; then
  cat <<'MSG'
Load it: about:debugging#/runtime/this-firefox -> Load Temporary Add-on ->
  pick manifest.json inside the folder above.

To publish: upload build/game-club-firefox.xpi (or the .zip) at
addons.mozilla.org/developers/addon/submit/distribution. Signing happens
there; an unsigned upload is rejected.
MSG
else
  echo 'Load it: chrome://extensions -> Developer mode -> Load unpacked -> select the folder above'
fi


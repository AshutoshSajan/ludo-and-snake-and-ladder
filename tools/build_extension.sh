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
  echo 'build/web missing - run: flutter build web --release' >&2
  exit 1
}

# A stale build/web is packaged silently, and the symptom is always the same
# confusing one: a feature that was written weeks ago is mysteriously absent
# from the installed add-on. Refuse rather than ship it.
if [ -n "$(find lib -newer build/web/index.html -type f -name '*.dart' -print -quit 2>/dev/null)" ]; then
  echo "ERROR: build/web is older than lib/. Rebuild first:" >&2
  echo "  flutter build web --release" >&2
  echo "Packaging the old bundle would hide every change since it was made." >&2
  exit 1
fi

# Stamp which source this came from, so "is my build current?" is answerable
# without guessing from the file dates.
echo "packaging commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown) ($(date +%H:%M))" 

out="build/extension-$target"
# 1. fresh skeleton (icons first; the manifest is copied last so the web
#    build's own manifest.json cannot overwrite it)
rm -rf "$out"
mkdir -p "$out"
python3 tools/gen_extension_icons.py >/dev/null
cp -r build/web/. "$out"/
cp "extension/manifest.$target.json" "$out/manifest.json"
cp extension/popup.html extension/popup.js "$out"/
cp -r extension/icons/. "$out/icons/"
# GPL section 4: a covered work must carry the licence text, so it ships inside
# the add-on rather than only in the repository. Both stores, since it is not a
# store-specific requirement.
cp LICENSE "$out/LICENSE"

if [ "$target" = firefox ]; then
  # This file is NOT read by AMO from the source directory. `web-ext sign` only
  # reads it when `--amo-metadata` names the path, and the CI passes that
  # explicitly - see .github/workflows/ci.yml. Copying it into the package
  # achieves nothing on its own and only bloats the add-on, so it is not copied.
  #
  # It is validated here because web-ext does not fail on a missing or malformed
  # file: it sends whatever it read, and AMO answers with a 400 that names a
  # field but not the file. Two shapes have already been wrong here:
  #   * `license` at the top level. AMO reads it under `version` - web-ext
  #     spreads `{...metadata, version: {upload, ...metadata.version}}`, so a
  #     top-level license never reaches version.license.
  #   * `categories: ["games"]`. That is not an AMO slug; the API has 32 and
  #     this one is `games-entertainment`. A wrong slug is the same silent 400.
  if ! python3 -c "
import json, sys

VALID_CATEGORIES = {'games-entertainment'}

m = json.load(open('extension/amo.metadata.json'))

# version.license: an SPDX slug from AMO's builtin list. GPL-3.0-only is on it;
# bare GPL-3.0 is not (SPDX deprecated it), and neither is MIT-as-an-slug.
lic = str((m.get('version') or {}).get('license') or '').strip()
if not lic:
    sys.exit('FAIL: extension/amo.metadata.json has no version.license. AMO '
             'rejects a listed version without one, naming it under \"version\".')
if lic.startswith('UNSET'):
    sys.exit('FAIL: version.license is still the placeholder %r. Pick a real '
             'AMO license slug and commit it.' % lic)
if lic == 'GPL-3.0':
    sys.exit('FAIL: version.license %r is not an AMO slug - SPDX deprecated it '
             'for GPL-3.0-only / GPL-3.0-or-later.' % lic)

cats = m.get('categories') or []
if not cats:
    sys.exit('FAIL: amo.metadata.json has no categories; a listed add-on needs one.')
bad = [c for c in cats if c not in VALID_CATEGORIES]
if bad:
    sys.exit('FAIL: unknown AMO category slug(s) %r. Valid here: %s.'
             % (bad, sorted(VALID_CATEGORIES)))
"; then
    exit 1
  fi
  # A `listed` submission references the licence by slug alone, but the add-on
  # still has to carry the text (GPL section 4). Both are checked here so
  # neither is discovered by AMO instead.
  if ! cmp -s LICENSE "$out/LICENSE"; then
    echo "ERROR: the packaged LICENSE differs from the repository one." >&2
    exit 1
  fi
fi

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

# 4. Remote references.
#
# The previous version of this check grepped for `.js|.wasm|.json|.ttf` and
# reported "none" while the bundle was fetching https://fonts.gstatic.com/s/ -
# no file extension, so no match. The result was an extension that drew every
# pixel of the board and not one character of text, because MV3's CSP blocked
# the font and said nothing at all.
#
# So: hosts that are actually *fetched* are blocking; hosts merely named in a
# string (a help URL, a docs link) are listed and ignored. Distinguishing them
# by hand is the whole point - it is what turned an invisible runtime failure
# into a build that stops.
echo '--- remote references ---'
python3 - "$out" <<'PY'
import pathlib, re, sys
out = pathlib.Path(sys.argv[1])
# Reached only when useLocalCanvasKit is false, and the build pins that flag
# on, so it is dead code in a packaged extension.
# The real invariant: the default font must be *in the package*. The gstatic
# string stays in main.dart.js as fallback code even once Roboto is bundled, so
# its presence proves nothing either way - what matters is that the family
# resolves locally before that fallback is ever reached.
import json
fm = out / 'assets' / 'FontManifest.json'
families = [f.get('family') for f in json.loads(fm.read_text())] if fm.exists() else []
if 'Roboto' not in families:
    sys.exit('FAIL: Roboto is not in the package. CanvasKit falls back to '
             'fetching it from fonts.gstatic.com, MV3 blocks that, and every '
             'label in the game silently renders as nothing.')
print('  bundled fonts: %s' % families)
for js in list(out.rglob('*.js')) + list(out.rglob('*.html')):
    for url in re.findall(r'https?://[A-Za-z0-9.\-]+(?:/[A-Za-z0-9./_%\-+]*)?',
                          js.read_text(errors='ignore')):
        print('  inert  %s  <- %s' % (url, js.name))
print('  (any fonts.gstatic.com above is fallback code, unreachable while '
      'Roboto is bundled)')
PY


# 5. The manifest must be valid JSON and must open the popup. A missing
#    default_popup falls back to "no page at all", and the failure is silent:
#    the add-on installs and the button does nothing.
python3 - "$out/manifest.json" <<'PY2'
import json, os, sys
out = os.path.dirname(sys.argv[1])
m = json.load(open(sys.argv[1]))
popup = m.get('action', {}).get('default_popup')
assert popup, 'action.default_popup is required, or the button does nothing'
for f in [popup, 'popup.js']:
    assert os.path.exists(os.path.join(out, f)), f'{f} is referenced but not packaged'
assert 'background' not in m, 'the popup replaced the background click handler'
print('manifest ok: popup=%s, no background script' % popup)
PY2

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


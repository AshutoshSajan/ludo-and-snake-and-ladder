import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The two extension manifests.
///
/// They exist as separate files because MV3 split the background model and the
/// browsers did not follow each other: Chrome runs the toolbar handler as a
/// service worker, Firefox has no service workers and requires an event page.
/// A manifest carrying `service_worker` is rejected by Firefox; one carrying
/// `scripts` is ignored by Chrome. Neither failure is loud at build time - the
/// add-on installs and then does nothing when clicked - so it is pinned here.
void main() {
  /// Hoisted so the later top-level tests can iterate both manifests too.
  final names = ['manifest.chrome.json', 'manifest.firefox.json'];

  Map<String, dynamic> load(String name) =>
      jsonDecode(File('extension/$name').readAsStringSync()) as Map<String, dynamic>;

  group('every manifest', () {
    test('are valid MV3 JSON with a name, version and icons', () {
      for (final n in names) {
        final m = load(n);
        expect(m['manifest_version'], 3, reason: n);
        expect(m['name'], isNotEmpty, reason: n);
        expect(m['version'], matches(RegExp(r'^\d+\.\d+\.\d+$')),
            reason: '$n: AMO rejects a version that is not x.y.z');
        expect((m['icons'] as Map), isNotEmpty, reason: n);
      }
    });

    test('carry a CSP that allows wasm but forbids remote script', () {
      // dart2js plus CanvasKit needs wasm-unsafe-eval; without it the engine
      // throws on load and the add-on shows a blank page.
      for (final n in names) {
        final csp = (load(n)['content_security_policy']
            as Map)['extension_pages'] as String;
        expect(csp, contains("script-src 'self'"), reason: n);
        expect(csp, contains("'wasm-unsafe-eval'"), reason: n);
        expect(csp, isNot(contains('*')), reason: '$n: a wildcard voids MV3');
      }
    });
  });

  test('both manifests open a popup, and declare no background', () {
    // A popup replaced the toolbar click handler, so neither browser needs a
    // background script - which also removed the only key that differed
    // between the two. Without default_popup the add-on installs and the
    // button does nothing, silently.
    for (final n in names) {
      final m = load(n);
      expect((m['action'] as Map)['default_popup'], 'popup.html', reason: n);
      expect(m.containsKey('background'), isFalse,
          reason: '$n: the popup handles the click; a background script is dead '
              'weight and Firefox would reject a service_worker one anyway');
    }
  });

  test('the popup and its script are packaged', () {
    for (final f in ['extension/popup.html', 'extension/popup.js']) {
      expect(File(f).existsSync(), isTrue, reason: '$f is missing');
    }
    // MV3 forbids inline script, so the handler has to be its own file.
    final html = File('extension/popup.html').readAsStringSync();
    expect(html, contains('src="popup.js"'));
    expect(html, isNot(contains('<script>')),
        reason: 'inline script is refused under the MV3 CSP');
  });

  test('the popup is a small launcher, and the game opens in a new tab', () {
    // Restored by request: playing inside the popup was capped at 800x600 and
    // the click-outside rule lost games mid-move. The launcher is back and the
    // game opens in a normal browser tab.
    // Comments stripped first: popup.js discusses chrome.windows.create in
    // prose (to say it is NOT what opens the game), and the raw file would
    // flag that explanation as a violation of itself.
    final html = File('extension/popup.html').readAsStringSync();
    final js = File('extension/popup.js')
        .readAsStringSync()
        .replaceAll(RegExp(r'//.*'), '');
    expect(html, contains('id="play"'),
        reason: 'the launcher needs its open-the-game control');
    expect(html, isNot(contains('<iframe')),
        reason: 'the game must not run inside the capped popup');
    // A small popup, not a game board: the width is what keeps it a launcher.
    expect(html, contains('width: 300px'));
    expect(js, contains('chrome.tabs.create'),
        reason: 'the game opens in a new tab');
    expect(js, isNot(contains('chrome.windows.create')),
        reason: 'a tab was asked for, not a dedicated window');
  });

  test('the launcher needs no permission the manifests do not declare', () {
    // The original launcher found the game's tab with
    // chrome.tabs.query({url}). Filtering tabs by URL requires the "tabs"
    // permission, neither manifest declares it, and so that query returned
    // nothing: the reuse path never ran and every click opened another tab.
    // chrome.tabs.create needs no permission, which is why it is used.
    //
    // The two halves of this are deliberately coupled: if someone adds reuse
    // via tabs.query, this fails until they also declare the permission - and
    // declaring it shows users a "read your browsing history" warning, which is
    // a decision that should be made on purpose.
    // Comments stripped first: popup.js explains in prose why it does NOT use
    // chrome.tabs.query, and asserting on the raw file would flag that
    // explanation as a violation of itself.
    final js = File('extension/popup.js')
        .readAsStringSync()
        .replaceAll(RegExp(r'//.*'), '');
    expect(js, isNot(contains('chrome.tabs.query')),
        reason: 'tabs.query by url needs the tabs permission, absent here');
    for (final m in ['extension/manifest.chrome.json',
        'extension/manifest.firefox.json']) {
      final manifest = jsonDecode(File(m).readAsStringSync()) as Map;
      expect((manifest['permissions'] as List?) ?? const [],
          isNot(contains('tabs')),
          reason: '$m: the launcher must not require the tabs permission');
    }
  });

  test('both manifests can reach the game server for online play', () {
    // Offline play needs nothing, but online play is a cross-origin fetch from
    // an extension page. Left undeclared it falls back to the default-src
    // behaviour, which is not the same in both browsers - so the one browser
    // that tightens it fails in a way that reads as a dead server.
    for (final n in names) {
      final m = load(n);
      final csp = (m['content_security_policy'] as Map)['extension_pages']
          as String;
      expect(csp, contains('connect-src'), reason: n);
      expect(csp, contains('https://ludo-1zpb.onrender.com'), reason: n);
    }
  });

  test('Firefox also declares host_permissions for the server', () {
    // Firefox gates a cross-origin fetch from an extension page on host
    // permissions, not only on connect-src, so it needs both.
    expect(load('manifest.firefox.json')['host_permissions'],
        contains('https://ludo-1zpb.onrender.com/*'));
  });

  test('the Firefox manifest carries the add-on id AMO demands', () {
    // Found by running `web-ext lint`, which reports ADDON_ID_REQUIRED:
    // addons.mozilla.org rejects a listed add-on with no browser_specific_
    // settings.gecko.id. It is the permanent identity, so it must not change
    // between uploads or a second add-on is created.
    final gecko = (load('manifest.firefox.json')['browser_specific_settings']
        as Map)['gecko'] as Map;
    expect(gecko['id'], isNotEmpty);
    expect('${gecko['id']}', contains('@'),
        reason: 'a gecko id is an email-shaped string or a GUID');
  });

  test('AMO metadata exists and is packaged for Firefox only', () {
    // Found by a real submission: web-ext sign uploaded the add-on and AMO
    // answered `Submission failed (2): Bad Request - "This field, or
    // custom_license, is required for listed versions."` The license is not in
    // the manifest; it goes in amo.metadata.json, which web-ext reads from the
    // extension source directory. A missing file is silent — web-ext sends
    // nothing and AMO decides — so both halves are pinned here.
    final meta = jsonDecode(File('extension/amo.metadata.json').readAsStringSync())
        as Map<String, dynamic>;
    expect(meta['license'], isA<String>(),
        reason: 'AMO rejects a listed version with no license');
    expect('${meta['license']}', isNot(startsWith('UNSET')),
        reason: 'the placeholder is not a licence grant');
    // AMO matches the SPDX list, where bare `GPL-3.0` is deprecated in favour
    // of the -only / -or-later forms. A deprecated id is one AMO may drop.
    expect('${meta['license']}', isNot('GPL-3.0'),
        reason: 'deprecated SPDX id; use GPL-3.0-only or GPL-3.0-or-later');
    expect(meta['categories'], isNotEmpty, reason: 'AMO requires categories');
    expect((meta['developer'] as Map)['name'], isNotEmpty);

    // GPL section 4 requires the licence text to travel with the covered work,
    // so the file is not just a repo-level courtesy - it has to be packaged.
    expect(File('LICENSE').existsSync(), isTrue,
        reason: 'the declared licence must have its text in the repo');
    expect(File('LICENSE').readAsStringSync(),
        contains('GNU GENERAL PUBLIC LICENSE'));
    final sh = File('tools/build_extension.sh').readAsStringSync();
    expect(sh, contains('amo.metadata.json'),
        reason: 'the metadata must be copied into the Firefox package');
    expect(sh, contains(r'cp LICENSE "$out/LICENSE"'),
        reason: 'the licence text must ship inside the add-on');
    // The placeholder is a stand-in, not a licence grant. Packaging it would
    // publish a licence the project never chose, so the build refuses instead.
    expect(sh, contains('UNSET'),
        reason: 'the build must refuse the placeholder license');
    // Chrome does not read this file; shipping it there adds bytes the Web
    // Store ignores. The LICENSE copy above is not store-specific, so it is
    // outside this guard deliberately.
    expect(sh, contains(r'if [ "$target" = firefox ]; then'));
  });

  test('the build script packages the popup and checks it', () {
    final sh = File('tools/build_extension.sh').readAsStringSync();
    expect(sh, contains('extension/popup.html extension/popup.js'),
        reason: 'the popup must be copied into the package');
    // The assertion is what turns "installed, button does nothing" into a
    // failed build.
    expect(sh, contains('action.default_popup is required'));
    // A service worker cannot run in an extension page at all.
    expect(sh, contains('flutter_service_worker.js'));
  });
}

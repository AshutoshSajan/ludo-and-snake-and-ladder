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

  test('the popup hosts the game itself, and still offers a tab', () {
    // Asked for directly: play from the popup without leaving the page. An
    // iframe rather than replacing the popup document, so the page can keep
    // the one control it still needs.
    final html = File('extension/popup.html').readAsStringSync();
    final js = File('extension/popup.js').readAsStringSync();
    expect(html, contains('<iframe id="game"'),
        reason: 'the game must be able to run inside the popup');
    expect(html, contains('src="index.html"'));
    // A popup closes when you click outside it. The tab escape hatch stays for
    // exactly that reason and must not be quietly removed.
    expect(html, contains('id="tab"'));
    expect(js, contains('chrome.tabs.create'));
  });

  test('the popup goes straight to the main screen, with no menu in front', () {
    // The launcher - a die, an "Open Game Club" button, a "Play online"
    // button - duplicated the app's own home screen and asked the same question
    // twice. It was removed on request, and it is easy to reintroduce by
    // accident because the old markup looks reasonable.
    // Comments are stripped first: popup.html explains in prose which buttons
    // it used to have, and that history is worth keeping. Checking the raw
    // file would flag its own explanation as a regression.
    final html = File('extension/popup.html')
        .readAsStringSync()
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    final js = File('extension/popup.js')
        .readAsStringSync()
        .replaceAll(RegExp(r'//.*'), '');
    for (final gone in ['id="launcher"', 'id="play"', 'id="online"',
        'id="back"', 'Open Game Club']) {
      expect(html, isNot(contains(gone)),
          reason: 'the popup must open on the main screen, not a menu: $gone');
    }
    expect(js, isNot(contains('classList.add')),
        reason: 'there is no longer a menu to dismiss');
    // The one surviving control, so the popup is not stripped bare.
    expect(html, contains('id="tab"'));
  });

  test('the game iframe is never display:none', () {
    // The bug this pins: a display:none iframe has a 0x0 viewport, so Flutter
    // measured itself at zero, rendered nothing, and did not re-layout when
    // the launcher was dismissed. The click looked like it did nothing. With
    // no launcher there is nothing to hide, and the frame is laid out and
    // visible from the first paint.
    final html = File('extension/popup.html').readAsStringSync();
    final rule = RegExp(r'#game\s*\{([^}]*)\}').firstMatch(html)?.group(1) ?? '';
    expect(rule, isNot(contains('display: none')),
        reason: 'a hidden iframe renders nothing');
    expect(rule, contains('position: absolute'),
        reason: 'it must fill the popup rather than sit in flow');
  });

  test('the popup is sized to the browser maximum', () {
    // A popup is capped at 800x600. Anything smaller shrinks a board that was
    // already tight.
    final html = File('extension/popup.html').readAsStringSync();
    expect(html, contains('width: 800px'));
    expect(html, contains('height: 600px'));
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

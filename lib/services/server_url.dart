/// Default game-server URL resolution for the report/contact lane.
///
/// Mirrors `OnlineLobbyScreen.defaultServerUrl` (precedence: the
/// GAME_SERVER_URL dart-define, web same-origin, hosted fallback) but
/// lives in the service layer so UI widgets do not have to import a
/// screen. A contract test pins the two implementations together, so a
/// change to one without the other fails CI instead of silently
/// pointing reports at the wrong host.
library;

import 'package:flutter/foundation.dart' show kIsWeb;

/// The hosted game server that packaged and web builds play against.
/// A packaged build is built once and installed everywhere, so it cannot
/// depend on a per-deployment dart-define — same constant meaning as the
/// lobby's [OnlineLobbyScreen.hostedServerUrl].
const hostedServerUrl = 'wss://ludo-1zpb.onrender.com/ws';

/// Precedence:
/// 1. `--dart-define=GAME_SERVER_URL=wss://host/ws` (build-time override)
/// 2. same-origin on web — single-service deploys and the dev server
/// 3. `ws://localhost:8080/ws` for desktop/mobile dev runs
String defaultServerUrl() {
  const configured = String.fromEnvironment('GAME_SERVER_URL');
  if (configured.isNotEmpty) return configured;
  if (kIsWeb && Uri.base.host.isNotEmpty) {
    return sameOriginServerUrl(Uri.base);
  }
  return 'ws://localhost:8080/ws';
}

/// Same-origin URL for a web page URI (see the lobby's identical helper
/// for the extension-scheme reasoning).
String sameOriginServerUrl(Uri page) {
  switch (page.scheme) {
    case 'https':
      return 'wss://${page.authority}/ws';
    case 'http':
      return 'ws://${page.host}:8080/ws';
    default:
      return hostedServerUrl;
  }
}

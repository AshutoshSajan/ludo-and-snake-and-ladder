import 'package:flutter/foundation.dart';

/// Build-time kill switch for special deploys:
/// `flutter build web --dart-define=ADMIN_UI=false`.
const bool adminUiEnabledByBuild = bool.fromEnvironment(
  'ADMIN_UI',
  defaultValue: true,
);

/// Whether the admin screens are reachable in this build. Exactly one
/// surface qualifies: the hosted web app. Native builds never compile the
/// screens (conditional imports on `dart.library.io`), packaged add-ons run
/// the same web code under a `chrome-extension://` / `moz-extension://`
/// origin rather than http(s), and the flag above covers the rest.
///
/// The sign-in session can only ever come from the gated /admin route, so
/// this single check is the whole surface: no route, no session, no door.
bool get isAdminUiAvailable {
  if (!kIsWeb || !adminUiEnabledByBuild) return false;
  final scheme = Uri.base.scheme;
  return scheme == 'http' || scheme == 'https';
}

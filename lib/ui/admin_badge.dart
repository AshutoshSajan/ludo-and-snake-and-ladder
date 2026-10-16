/// Platform split for the admin identity badge.
///
/// The web app gets the real badge ([admin_badge_web.dart]); native builds
/// resolve the no-op stub ([admin_badge_stub.dart]) so the admin screens are
/// compiled into no desktop/mobile binary. (Browser extensions run the same
/// web code — they are excluded at runtime by [isAdminUiAvailable], and a
/// session can only ever come from the gated /admin route, so no badge can
/// surface there either.)
library;

export 'admin_badge_web.dart' if (dart.library.io) 'admin_badge_stub.dart';

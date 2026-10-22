/// Web Share API glue for the room-code card.
///
/// `navigator.share` opens the operating system's share sheet (WhatsApp,
/// Messages, email, …). It only works from a user gesture on a secure
/// origin, and it is not present in every browser, so every failure —
/// unsupported, permission denied, or the player dismissing the sheet —
/// answers `false` and the caller copies the link instead.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<bool> shareJoinLink(
  String url, {
  String title = 'Game Club',
  String? text,
}) async {
  try {
    final data = web.ShareData(
      title: title,
      text: text ?? 'Join my Game Club room',
      url: url,
    );
    // `canShare` is the cheap availability check; calling `share` on a
    // browser that does not implement it throws instead of returning.
    if (!web.window.navigator.canShare(data)) return false;
    await web.window.navigator.share(data).toDart;
    return true;
  } catch (_) {
    return false;
  }
}

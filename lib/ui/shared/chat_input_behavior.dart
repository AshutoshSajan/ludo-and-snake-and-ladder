/// Chat composer reply grammar, resolved per platform.
///
/// Desktop chats share one grammar everyone leans on: Enter sends, and the
/// Send button is for when the mouse is faster. Phone IMEs spell Enter as
/// "newline" on a multiline field and there the Send button is the reply
/// path, so the gate stays false. This maps correctly on the web too — the
/// engine surfaces the browser's OS through [defaultTargetPlatform], so a
/// phone browser is `android`/`ios` and a desktop browser is `linux`/
/// `windows`/`macos`.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;

/// Settable by tests so the composer can exercise the desktop path with the
/// framework's default (test = Android) target platform.
@visibleForTesting
bool chatEnterSendsOverride = false;

/// Whether the Enter key on a multiline composer sends the message.
/// Shift+Enter behaves the same as Enter here: a desktop keyboard slugging
/// out a newline mid-chat is rare, and making half the keys send and the
/// other half not is the kind of trivia nobody wins.
bool get chatEnterSends =>
    chatEnterSendsOverride ||
    switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };

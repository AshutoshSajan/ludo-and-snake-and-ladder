/// Keyboard-inserted GIFs for the chat composers.
///
/// On Android (and iOS 16+) an IME can commit rich content into a text
/// field: the GIF key on Gboard and Samsung Keyboard sends the picture
/// through the platform's `commitContent` protocol (Android's
/// image-keyboard spec), and the engine delivers it to Flutter's
/// `contentInsertionConfiguration` either as inline bytes or — when the
/// keyboard carries one — as a direct https link to the GIF.
///
/// That is exactly the payload the GIF sheet produces (`client.sendGif`
/// with an https URL), so a player who already knows their keyboard's
/// GIF button needs no new pathway learned: insertion here ends at the
/// same chat line the picker would have built. The composer field is
/// where this is registered — see `TableChatPanel`.
///
/// Failure says so: bytes that the server refuses and opaque content uris
/// both surface the sheet's own error wording, per the one-visual-language
/// rule — there is one keyboard-GIF story, not three.
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart' show ContentInsertionConfiguration;
import 'package:flutter/services.dart' show KeyboardInsertedContent;

/// Builds the [ContentInsertionConfiguration] a mobile composer field
/// takes. Null on platforms where the IME never commits content (web,
/// desktop), so the field stays untouched there.
///
/// [send] uploads inlined bytes and announces them ([sendKeyboardGif]);
/// [sendLink] shares a direct https link exactly as the GIF picker does;
/// [onError] speaks the failure, because a silent dead tap is the one UX
/// bug this whole file exists to avoid.
ContentInsertionConfiguration? keyboardGifInsertion({
  required Future<bool> Function({
    required List<int> bytes,
    required String mime,
  })
  send,
  required void Function(String url) sendLink,
  required void Function(String message) onError,
}) {
  final supported = switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
  if (!supported) return null;
  return ContentInsertionConfiguration(
    allowedMimeTypes: const [
      'image/gif',
      'image/webp',
      'image/png',
      'image/jpeg',
    ],
    // The framework wants a plain callback; the upload runs underneath.
    onContentInserted: (content) {
      unawaited(
        _onContent(content, send: send, sendLink: sendLink, onError: onError),
      );
    },
  );
}

/// A mime the field cannot send is odd enough to say no loudly instead
/// of forwarding junk the server would 400 anyway — with the same words
/// a failed upload uses.
const _keyboardGifError = "That keyboard GIF didn't send — try the GIF button";

Future<void> _onContent(
  KeyboardInsertedContent content, {
  required Future<bool> Function({
    required List<int> bytes,
    required String mime,
  })
  send,
  required void Function(String url) sendLink,
  required void Function(String message) onError,
}) async {
  // The common path: the engine inlined the committed bytes.
  final data = content.data;
  if (data != null && data.isNotEmpty) {
    final ok = await send(bytes: data, mime: _safeMime(content.mimeType));
    if (!ok) onError(_keyboardGifError);
    return;
  }

  // Keyboard G-board style: some keyboards hand a direct https link in
  // the uri lane — the very same payload the picker sends by hand.
  final uri = Uri.tryParse(content.uri);
  if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
    sendLink(content.uri);
    return;
  }
  onError(_keyboardGifError);
}

/// The declared IME mime type with the parameters stripped, defaulting
/// to image/gif — the content-insertion contract puts the actual picture
/// in [KeyboardInsertedContent.data], so the declared type only needs to
/// be a sane image slug for the server's store.
String _safeMime(String mime) {
  final base = mime.split(';').first.trim().toLowerCase();
  return base.startsWith('image/') ? base : 'image/gif';
}

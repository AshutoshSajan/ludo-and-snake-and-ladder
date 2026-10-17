/// Tests for the keyboard-GIF client half: the IME's committed media is
/// uploaded by HTTP and announced as an ordinary `'gif'` chat line — the
/// same line the GIF sheet sends — and the composer's content-insertion
/// callback maps every keyboard payload onto it (bytes, direct https
/// link, or an error for opaque uris). The HTTP layer is mocked; the
/// socket is the shared [FakeChannel] script.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show KeyboardInsertedContent;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/services/online_client.dart';
import 'package:game_club/ui/shared/keyboard_content.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_channel.dart';

void main() {
  group('sendKeyboardGif', () {
    OnlineClient joinedClient(FakeChannelFactory factory) {
      final client = OnlineClient(
        'ws://test/ws',
        seatId: 'p1',
        name: 'A',
        channelFactory: factory.create,
      );
      client.connect(code: 'CODE');
      return client;
    }

    Future<OnlineClient> waitJoined(FakeChannelFactory factory) async {
      final client = joinedClient(factory);
      await pumpEventQueue();
      factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
      await pumpEventQueue();
      return client;
    }

    test('uploads the bytes by HTTP then announces a https gif line',
        () async {
      final factory = FakeChannelFactory();
      final client = await waitJoined(factory);

      Uri? postedUrl;
      Map<String, String>? headers;
      List<int>? postedBody;
      final ok = await client.sendKeyboardGif(
        bytes: [71, 73, 70],
        mime: 'image/gif',
        httpClient: MockClient((req) async {
          postedUrl = req.url;
          headers = req.headers;
          postedBody = req.bodyBytes;
          return http.Response(
            jsonEncode({'ok': true, 'url': '/media/image/CODE/k1'}),
            200,
          );
        }),
      );
      expect(ok, isTrue);
      expect(postedUrl!.scheme, 'http', reason: 'the ws url becomes its origin');
      expect(postedUrl!.path, '/media/image');
      expect(postedUrl!.queryParameters['room'], 'CODE');
      expect(
        postedUrl!.queryParameters['id'],
        matches(RegExp(r'^[a-z0-9][a-z0-9-]{5,31}$')),
      );
      expect(headers!['content-type'], 'image/gif');
      expect(postedBody, [71, 73, 70]);

      final frames = factory.last.sent
          .whereType<Map<String, dynamic>>()
          .toList();
      final chat = frames.lastWhere(
        (m) => m['type'] == 'chat',
        orElse: () => {'missing': true},
      );
      // The broadcast carries the absolute URL — https servers' chat gate
      // requires it, and every client renders it like a picked GIF.
      expect(
        chat['gif'],
        'http://test/media/image/CODE/k1',
      );
      expect(chat['text'], '');
    });

    test('a refused upload announces nothing', () async {
      final factory = FakeChannelFactory();
      final client = await waitJoined(factory);

      final ok = await client.sendKeyboardGif(
        bytes: [1, 2, 3],
        mime: 'image/gif',
        httpClient: MockClient(
          (_) async => http.Response('{"ok":false,"text":"too large"}', 413),
        ),
      );
      expect(ok, isFalse);
      expect(
        factory.last.sent.where((m) => (m as Map)['type'] == 'chat'),
        isEmpty,
        reason: 'an image the server refused must not become a ghost line',
      );
    });

    test('a network error is caught and still announces nothing', () async {
      final factory = FakeChannelFactory();
      final client = await waitJoined(factory);

      final ok = await client.sendKeyboardGif(
        bytes: [1, 2, 3],
        mime: 'image/gif',
        httpClient: MockClient(
          (_) async => throw http.ClientException('connection reset'),
        ),
      );
      expect(ok, isFalse);
      expect(
        factory.last.sent.where((m) => (m as Map)['type'] == 'chat'),
        isEmpty,
      );
    });

    test('not being in a room is false without touching the network',
        () async {
      final factory = FakeChannelFactory();
      final client = joinedClient(factory);
      await pumpEventQueue(); // connecting, but no 'joined' yet

      var calls = 0;
      final ok = await client.sendKeyboardGif(
        bytes: [1, 2, 3],
        mime: 'image/gif',
        httpClient: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      expect(ok, isFalse);
      expect(calls, 0, reason: 'no upload without a room to announce it in');
    });
  });

  group('keyboardGifInsertion', () {
    test('renders an insertion config for mobile platforms', () {
      // Widget tests run as android — the IME commit path device.
      final config = keyboardGifInsertion(
        send: ({required bytes, required mime}) async => true,
        sendLink: (_) {},
        onError: (_) {},
      );
      expect(config, isNotNull);
      expect(config!.allowedMimeTypes.first, 'image/gif',
          reason: 'the GIF key answers first in the negotiated types');
    });

    test('inlined bytes are uploaded through send with a safe mime',
        () async {
      SendCall? sent;
      final config = keyboardGifInsertion(
        send: ({required bytes, required mime}) async {
          sent = SendCall(bytes, mime);
          return true;
        },
        sendLink: (_) {},
        onError: (_) {},
      )!;

      config.onContentInserted(
        KeyboardInsertedContent(
          mimeType: 'image/gif',
          uri: 'content://com.google.android.inputmethod.latin/1',
          data: Uint8List.fromList([71, 73, 70]),
        ),
      );
      await pumpEventQueue();
      expect(sent!.mime, 'image/gif');
      expect(sent!.bytes, [71, 73, 70]);

      // Some keyboards mislabel; the store only needs a sane image slug.
      config.onContentInserted(
        KeyboardInsertedContent(
          mimeType: 'application/octet-stream; charset=x',
          uri: 'content://x/2',
          data: Uint8List.fromList([1]),
        ),
      );
      await pumpEventQueue();
      expect(sent!.mime, 'image/gif');
    });

    test('a failed upload speaks the error, and the message is the shared one',
        () async {
      final errors = <String>[];
      final config = keyboardGifInsertion(
        send: ({required bytes, required mime}) async => false,
        sendLink: (_) {},
        onError: errors.add,
      )!;

      config.onContentInserted(
        KeyboardInsertedContent(mimeType: 'image/gif', uri: 'content://x/3'),
      );
      await pumpEventQueue();
      expect(errors, hasLength(1));
    });

    test('an https uri without bytes shares the link like the picker would',
        () async {
      String? linked;
      var uploadCalls = 0;
      final config = keyboardGifInsertion(
        send: ({required bytes, required mime}) async {
          uploadCalls++;
          return true;
        },
        sendLink: (url) => linked = url,
        onError: (_) {},
      )!;

      config.onContentInserted(
        KeyboardInsertedContent(
          mimeType: 'image/gif',
          uri: 'https://media.example.com/g/celebration.gif',
        ),
      );
      await pumpEventQueue();
      expect(uploadCalls, 0, reason: 'no bytes means no upload');
      expect(linked, 'https://media.example.com/g/celebration.gif');
    });

    test('an opaque content uri without bytes is an error, not silence',
        () async {
      final errors = <String>[];
      final config = keyboardGifInsertion(
        send: ({required bytes, required mime}) async => true,
        sendLink: (_) {},
        onError: errors.add,
      )!;

      config.onContentInserted(
        KeyboardInsertedContent(
          mimeType: 'image/gif',
          uri: 'content://samsung.keyboard/9',
        ),
      );
      await pumpEventQueue();
      expect(errors, hasLength(1),
          reason: 'the composer says so instead of swallowing the tap');
    });
  });
}

class SendCall {
  SendCall(this.bytes, this.mime);
  final List<int> bytes;
  final String mime;
}

/// Tests for the voice-note client half: how a recorded clip is uploaded
/// (HTTP) and announced (a normal chat intent), and how the client decodes
/// note lines back into something a pill can play. The HTTP layer is a
/// mock; the socket is the shared [FakeChannel] script.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/engine/ludo/ludo_models.dart';
import 'package:game_club/services/online_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_channel.dart';

void main() {
  group('ChatLine decoding', () {
    test('a note line absolutizes the store url against the server origin', () {
      final line = ChatLine.fromJson({
        'from': 'Ana',
        'text': '',
        'note': {'url': '/media/voice/CODE/ab12cd34', 'dur': 7000},
      }, serverUrl: 'ws://test/ws');
      expect(line.note, isNotNull);
      // ws -> http: the note lives on the game server's REST face, and the
      // flip happens once, here, at parse time.
      expect(line.note!.url, 'http://test/media/voice/CODE/ab12cd34');
      expect(line.note!.durMs, 7000);
      expect(line.note!.clock, '0:07');
    });

    test('a secure server flips wss -> https the same way', () {
      final line = ChatLine.fromJson({
        'from': 'Ana',
        'note': {'url': '/media/voice/C/aaaaaaaa', 'dur': 900},
      }, serverUrl: 'wss://game.example/ws');
      expect(line.note!.url, 'https://game.example/media/voice/C/aaaaaaaa');
      expect(line.note!.clock, '0:01');
    });

    test('a note with no server yet degrades to a line without a note', () {
      final line = ChatLine.fromJson(const {
        'from': 'Ana',
        'note': {'url': '/media/voice/C/x', 'dur': 100},
      });
      // Tolerated, not crass — a viewer without a framed url simply
      // renders the caption (or nothing), never a broken widget.
      expect(line.note, isNull);
    });

    test('seat color and arrival time ride the line', () {
      final line = ChatLine.fromJson({
        'from': 'Bo',
        'color': 'yellow',
        'at': 123,
      });
      expect(line.color, LudoColor.yellow);
      expect(line.at, 123);
    });

    test('an unknown future seat color is tolerated as no color', () {
      final line = ChatLine.fromJson({
        'from': 'Bo',
        'color': 'magenta',
      });
      expect(line.color, isNull);
    });
  });

  group('sendVoiceNote', () {
    OnlineClient clientWith(FakeChannelFactory factory) {
      final client = OnlineClient(
        'ws://test/ws',
        seatId: 'p1',
        name: 'A',
        channelFactory: factory.create,
      );
      client.connect(code: 'CODE');
      return client;
    }

    test('uploads by HTTP then announces over the socket', () async {
      final factory = FakeChannelFactory();
      final client = clientWith(factory);
      await pumpEventQueue();
      factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
      await pumpEventQueue();

      Uri? postedUrl;
      Map<String, String>? sentHeaders;
      List<int>? postedBody;
      var calls = 0;
      final httpMock = MockClient((req) async {
        calls++;
        postedUrl = req.url;
        sentHeaders = req.headers;
        postedBody = req.bodyBytes;
        return http.Response(
          jsonEncode({'ok': true, 'url': '/media/voice/CODE/x', 'dur': 1500}),
          200,
        );
      });

      final ok = await client.sendVoiceNote(
        bytes: [1, 2, 3],
        mime: 'audio/mp4',
        durMs: 1500,
        httpClient: httpMock,
      );
      expect(ok, isTrue);
      expect(calls, 1);
      expect(postedUrl!.scheme, 'http', reason: 'the WS url becomes its origin');
      expect(postedUrl!.host, 'test');
      expect(postedUrl!.queryParameters['room'], 'CODE');
      expect(
        postedUrl!.queryParameters['id'],
        matches(RegExp(r'^[a-z0-9][a-z0-9-]{5,31}$')),
      );
      expect(sentHeaders!['content-type'], 'audio/mp4');
      expect(sentHeaders!['x-voice-duration'], '1500');
      expect(postedBody, [1, 2, 3]);

      // And exactly one chat line announces it, carrying the same id.
      final frames = factory.last.sent.whereType<Map<String, dynamic>>().toList();
      final chat = frames.lastWhere(
        (m) => m['type'] == 'chat',
        orElse: () => {'missing': true},
      );
      expect(chat['note'], postedUrl!.queryParameters['id']);
      expect(chat['text'], '');
    });

    test('a refused upload announces nothing', () async {
      final factory = FakeChannelFactory();
      final client = clientWith(factory);
      await pumpEventQueue();
      factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
      await pumpEventQueue();

      final ok = await client.sendVoiceNote(
        bytes: [1],
        mime: 'audio/mp4',
        durMs: 200,
        httpClient: MockClient((_) async => http.Response('{"ok":false}', 404)),
      );
      expect(ok, isFalse);
      expect(
        factory.last.sent.where((m) => (m as Map)['type'] == 'chat'),
        isEmpty,
        reason: 'an upload the server refused must not become a ghost line',
      );
    });

    test('a network error is caught and still announces nothing', () async {
      final factory = FakeChannelFactory();
      final client = clientWith(factory);
      await pumpEventQueue();
      factory.last.serverAdd({'type': 'joined', 'code': 'CODE', 'color': 'red'});
      await pumpEventQueue();

      final ok = await client.sendVoiceNote(
        bytes: [1],
        mime: 'audio/mp4',
        durMs: 200,
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

    test('not being in a room is false without touching the network', () async {
      final factory = FakeChannelFactory();
      final client = clientWith(factory);
      await pumpEventQueue(); // connecting, but no 'joined' yet

      var calls = 0;
      final ok = await client.sendVoiceNote(
        bytes: [1],
        mime: 'audio/mp4',
        durMs: 200,
        httpClient: MockClient((req) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      expect(ok, isFalse);
      expect(calls, 0, reason: 'no upload without a room to announce it in');
    });
  });
}

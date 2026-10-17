/// Tests for the chat voice-note server: the [VoiceNoteStore]'s caps and
/// sweeps, and the upload/serve endpoints' refusals. The store takes an
/// injectable clock so TTL behaviour is deterministic, not slept.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_club/server/voice_notes.dart';
import 'package:shelf/shelf.dart' as shelf;

/// A DateTime advance-by knob for the store's clock.
class _Clock {
  DateTime now = DateTime(2026, 1, 1, 12);
}

VoiceNoteStore _store(_Clock clock, {int? maxPerRoom, int? maxBytes}) =>
    VoiceNoteStore(
      now: () => clock.now,
      maxPerRoom: maxPerRoom ?? 24,
      maxBytes: maxBytes ?? 32 * 1024 * 1024,
    );

Future<shelf.Response> _upload(
  shelf.Request req, {
  required VoiceNoteStore store,
  bool live = true,
}) => voiceNoteUpload(req, store: store, roomIsLive: (_) => live);

void main() {
  group('VoiceNoteStore', () {
    test('a stored note round trips through get() with its url path', () {
      final store = _store(_Clock());
      final data = Uint8List.fromList([1, 2, 3]);
      final note = store.put(
        code: 'ROOM',
        id: 'abcdefgh',
        data: data,
        mime: 'audio/mp4',
        durMs: 1500,
      );
      expect(note, isNotNull);
      expect(note!.urlPath, '/media/voice/ROOM/abcdefgh');
      final back = store.get('ROOM', 'abcdefgh');
      expect(back!.data, data);
      expect(back.mime, 'audio/mp4');
      expect(back.durMs, 1500);
      expect(store.totalBytes, 3);
    });

    test('a malformed id is refused — it ends up in a URL path', () {
      final store = _store(_Clock());
      final data = Uint8List.fromList([1]);
      for (final bad in [
        '', // nothing at all
        'ABCdef', // the pattern is lowercase only
        'abc', // too short (needs 6+)
        '-abcde', // must start [a-z0-9]
        'a' * 33, // 33 — past the 32 cap
        'abc de', // spaces are junk
      ]) {
        expect(
          store.put(code: 'ROOM', id: bad, data: data, mime: 'audio/mp4', durMs: 500),
          isNull,
          reason: 'id "$bad" must not be storable',
        );
      }
    });

    test('empty or oversized bodies and silly durations are refused', () {
      final store = _store(_Clock());
      final filler = Uint8List(store.maxNoteBytes + 1);
      expect(
        store.put(
          code: 'R',
          id: 'aaaaaa',
          data: Uint8List(0),
          mime: 'audio/mp4',
          durMs: 500,
        ),
        isNull,
        reason: 'an empty note is not a note',
      );
      expect(
        store.put(code: 'R', id: 'aaaaaa', data: filler, mime: 'audio/mp4', durMs: 500),
        isNull,
        reason: 'past the per-note cap',
      );
      expect(
        store.put(code: 'R', id: 'aaaaaa', data: Uint8List(4), mime: 'audio/mp4', durMs: 50),
        isNull,
        reason: 'under 100 ms is a recording accident',
      );
      expect(
        store.put(code: 'R', id: 'aaaaaa', data: Uint8List(4), mime: 'audio/mp4', durMs: 61_000),
        isNull,
        reason: 'past the recorder cap',
      );
      expect(store.totalBytes, 0);
    });

    test('a full room evicts its oldest note to make room', () {
      final store = _store(_Clock(), maxPerRoom: 2);
      for (final id in ['aaaaaa', 'bbbbbb', 'cccccc']) {
        store.put(
          code: 'ROOM',
          id: id,
          data: Uint8List.fromList([id.codeUnitAt(0)]),
          mime: 'audio/mp4',
          durMs: 500,
        );
      }
      expect(store.get('ROOM', 'aaaaaa'), isNull, reason: 'oldest yielded');
      expect(store.get('ROOM', 'bbbbbb'), isNotNull);
      expect(store.get('ROOM', 'cccccc'), isNotNull);
      expect(store.roomsStats['ROOM'], 2);
    });

    test('the global byte budget evicts the oldest note anywhere', () {
      final store = _store(_Clock(), maxBytes: 8);
      store.put(code: 'R1', id: 'aaaaaa', data: Uint8List(4), mime: 'audio/mp4', durMs: 500);
      store.put(code: 'R2', id: 'aaaaaa', data: Uint8List(4), mime: 'audio/mp4', durMs: 500);
      // A third four-byte note cannot exist under a 8-byte budget.
      final third = store.put(
        code: 'R0',
        id: 'aaaaaa',
        data: Uint8List(4),
        mime: 'audio/mp4',
        durMs: 500,
      );
      expect(third, isNotNull, reason: 'the budget evicted a victim first');
      expect(store.totalBytes, lessThanOrEqualTo(8));
      expect(store.get('R1', 'aaaaaa'), isNull, reason: 'R1 was the oldest');
    });

    test('notes older than the TTL are swept on the next touch', () {
      final clock = _Clock();
      final store = _store(clock);
      store.put(code: 'R', id: 'aaaaaa', data: Uint8List(4), mime: 'audio/mp4', durMs: 500);
      clock.now = clock.now.add(const Duration(hours: 25));
      expect(store.get('R', 'aaaaaa'), isNull, reason: 'a day old is gone');
      expect(store.roomsStats, isEmpty);
      expect(store.totalBytes, 0);
    });
  });

  group('voiceNoteUpload', () {
    final data = Uint8List.fromList([9, 8, 7]);

    Future<shelf.Response> post(
      VoiceNoteStore store, {
      String? room = 'ROOM',
      String? id = 'abcdefgh',
      String mime = 'audio/mp4',
      String? duration = '1200',
      List<int>? body,
    }) => _upload(
      shelf.Request(
        'POST',
        Uri.parse(
          'http://s/media/voice'
          '?room=${room ?? ''}&id=${id ?? ''}',
        ),
        headers: {
          'content-type': ?mime.isEmpty ? null : mime,
          'x-voice-duration': ?duration,
        },
        body: body ?? data,
      ),
      store: store,
    );

    test('a good upload answers 200 with the store url and duration', () async {
      final store = _store(_Clock());
      final res = await post(store);
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['url'], '/media/voice/ROOM/abcdefgh');
      expect(body['dur'], 1200);
      expect(store.get('ROOM', 'abcdefgh'), isNotNull);
    });

    test('a note for a room that is not live here is a 404', () async {
      final res = await _upload(
        shelf.Request(
          'POST',
          Uri.parse('http://s/media/voice?room=X&id=abcdefgh'),
          headers: {'content-type': 'audio/mp4', 'x-voice-duration': '1200'},
          body: data,
        ),
        store: _store(_Clock()),
        live: false,
      );
      expect(res.statusCode, 404);
    });

    test('non-audio content types are refused', () async {
      final res = await post(_store(_Clock()), mime: 'text/plain');
      expect(res.statusCode, 400);
      final res2 = await post(_store(_Clock()), mime: '');
      expect(res2.statusCode, 400);
    });

    test('a missing duration header is a 400, not a stored 0', () async {
      final store = _store(_Clock());
      final res = await post(store, duration: null);
      expect(res.statusCode, 400);
      expect(store.totalBytes, 0);
    });

    test('a malformed id or an unknown game reaches the store check', () async {
      // The store validates ids again after the endpoint's own gates — the
      // upload answers 400 for a malformed id either way.
      final res = await post(_store(_Clock()), id: 'Bad_ID');
      expect(res.statusCode, 400);
    });

    test('a body past the per-note cap is a 413 mid-stream', () async {
      final res = await post(
        _store(_Clock()),
        body: Uint8List(2 * 1024 * 1024 + 1),
      );
      expect(res.statusCode, 413);
    });

    test('GET on the upload path is 405', () async {
      final res = await _upload(
        shelf.Request(
          'GET',
          Uri.parse('http://s/media/voice?room=ROOM&id=abcdefgh'),
        ),
        store: _store(_Clock()),
      );
      expect(res.statusCode, 405);
    });
  });

  group('voiceNoteServe', () {
    test('a stored note is served back with its mime and no-store', () async {
      final store = _store(_Clock());
      store.put(
        code: 'ROOM',
        id: 'abcdefgh',
        data: Uint8List.fromList([4, 5]),
        mime: 'audio/mp4',
        durMs: 900,
      );
      final res = voiceNoteServe(
        shelf.Request('GET', Uri.parse('http://s/media/voice/ROOM/abcdefgh')),
        store: store,
      );
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'audio/mp4');
      expect(res.headers['cache-control'], 'no-store');
      expect(res.headers['accept-ranges'], 'none');
      final bytes = await res.read().fold<List<int>>(
        [],
        (acc, chunk) => acc..addAll(chunk),
      );
      expect(bytes, [4, 5]);
    });

    test('HEAD answers like GET, without the body', () async {
      final store = _store(_Clock());
      store.put(
        code: 'ROOM',
        id: 'abcdefgh',
        data: Uint8List.fromList([4, 5]),
        mime: 'audio/mp4',
        durMs: 900,
      );
      final res = voiceNoteServe(
        shelf.Request('HEAD', Uri.parse('http://s/media/voice/ROOM/abcdefgh')),
        store: store,
      );
      // The body travels (shelf_io strips it for HEAD at the socket) —
      // status and headers are the contract here.
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'audio/mp4');
    });

    test('an unknown note, room, or path shape is a 404', () {
      expect(
        voiceNoteServe(
          shelf.Request('GET', Uri.parse('http://s/media/voice/ROOM/nnnnnn')),
          store: _store(_Clock()),
        ).statusCode,
        404,
      );
      expect(
        voiceNoteServe(
          shelf.Request('GET', Uri.parse('http://s/media/voice/nospace')),
          store: _store(_Clock()),
        ).statusCode,
        404,
      );
    });

    test('writing to a serve path is 405', () {
      expect(
        voiceNoteServe(
          shelf.Request('POST', Uri.parse('http://s/media/voice/ROOM/abcdefgh')),
          store: _store(_Clock()),
        ).statusCode,
        405,
      );
    });
  });
}
